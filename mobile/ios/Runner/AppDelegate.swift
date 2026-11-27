import Flutter
import UIKit
import Vision

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ReceiptOcr") {
      ReceiptOcr.register(with: registrar)
    }
  }
}

/// Reads the text on a receipt photo with Apple's built-in text reader (Vision): on the phone,
/// offline and free. Returns pieces of text with their box (0..1, measured from the top-left)
/// and slope; the Dart side (TextLines + ReceiptParser) turns them into receipt lines exactly
/// like the web app does. Channel "budget/ocr", method "read" {path, rotation: 0/90/180/270}.
class ReceiptOcr: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "budget/ocr", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(ReceiptOcr(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "read" else { return result(FlutterMethodNotImplemented) }
    let args = call.arguments as? [String: Any] ?? [:]
    guard let path = args["path"] as? String, let image = UIImage(contentsOfFile: path), let cg = image.cgImage else {
      return result(FlutterError(code: "no_image", message: "The photo could not be opened.", details: nil))
    }
    let rotation = args["rotation"] as? Int ?? 0
    let orientation = ReceiptOcr.turned(CGImagePropertyOrientation(image.imageOrientation), by: rotation)
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let pieces = try ReceiptOcr.recognize(cg, orientation)
        DispatchQueue.main.async { result(pieces) }
      } catch {
        DispatchQueue.main.async { result(FlutterError(code: "ocr_failed", message: error.localizedDescription, details: nil)) }
      }
    }
  }

  /// The photo turned clockwise by 90, 180 or 270 degrees.
  static func turned(_ o: CGImagePropertyOrientation, by degrees: Int) -> CGImagePropertyOrientation {
    let cycle: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
    let mirrored: [CGImagePropertyOrientation] = [.upMirrored, .rightMirrored, .downMirrored, .leftMirrored]
    let ring = cycle.contains(o) ? cycle : mirrored
    let i = ring.firstIndex(of: o) ?? 0
    let steps = ((degrees / 90) % 4 + 4) % 4
    return ring[(i + steps) % 4]
  }

  static func recognize(_ cg: CGImage, _ orientation: CGImagePropertyOrientation) throws -> [[String: Any]] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    // Product names and codes are not dictionary words; "correcting" them makes it worse.
    request.usesLanguageCorrection = false
    // Vision has no Slovenian on older iOS; German and English cover the letters on Slovenian
    // receipts. Item names are compared without accents, so č/š/ž read as c/s/z does not matter.
    let supported = (try? request.supportedRecognitionLanguages()) ?? []
    request.recognitionLanguages = ["sl-SI", "hr-HR", "de-DE", "en-US"].filter { supported.contains($0) }
    try VNImageRequestHandler(cgImage: cg, orientation: orientation).perform([request])
    // Width / height of the photo as Vision reads it (turned), for the row slope in Dart.
    let sideways: Set<CGImagePropertyOrientation> = [.left, .leftMirrored, .right, .rightMirrored]
    let aspect = sideways.contains(orientation)
      ? Double(cg.height) / Double(max(cg.width, 1)) : Double(cg.width) / Double(max(cg.height, 1))
    var pieces: [[String: Any]] = []
    for obs in request.results ?? [] {
      guard let candidate = obs.topCandidates(1).first else { continue }
      let text = candidate.string
      // The observation's own corners are a straight box; the candidate's box for its whole text
      // follows the tilt of a photo taken at an angle. If Vision cannot give it, the slope is 0
      // and the Dart side works it out from the rows.
      let quad = (try? candidate.boundingBox(for: text.startIndex..<text.endIndex)) ?? nil
      let dx = (quad?.bottomRight.x ?? 0) - (quad?.bottomLeft.x ?? 0)
      let dy = (quad?.bottomRight.y ?? 0) - (quad?.bottomLeft.y ?? 0)
      let slope = dx > 0 ? -Double(dy / dx) : 0
      // Vision sometimes reads two or more receipt lines of the name column as one piece
      // ("MASLO 250G JAJCA M 10 KOM"), which puts every price below it on the wrong product.
      // So each word gets its own box, and the words are put back together row by row.
      for run in ReceiptOcr.rows(of: candidate, text) ?? [(text, obs.boundingBox)] {
        // Vision measures from the bottom-left; the Dart side wants the top-left.
        let b = run.1
        pieces.append([
          "text": run.0,
          "minX": Double(b.minX), "minY": Double(1 - b.maxY),
          "maxX": Double(b.maxX), "maxY": Double(1 - b.minY),
          "slope": slope,
          "aspect": aspect,
        ])
      }
    }
    return pieces
  }

  /// The text of a piece split into rows: words whose middles are closer than half a word's
  /// height are on the same row. nil when Vision cannot give the words' boxes (then the piece is
  /// used whole, as before).
  static func rows(of candidate: VNRecognizedText, _ text: String) -> [(String, CGRect)]? {
    var words: [(String, CGRect)] = []
    var i = text.startIndex
    while i < text.endIndex {
      while i < text.endIndex, text[i].isWhitespace { i = text.index(after: i) }
      guard i < text.endIndex else { break }
      var j = i
      while j < text.endIndex, !text[j].isWhitespace { j = text.index(after: j) }
      guard let box = (try? candidate.boundingBox(for: i..<j)) ?? nil else { return nil }
      words.append((String(text[i..<j]), box.boundingBox))
      i = j
    }
    if words.isEmpty { return nil }
    var out: [(String, CGRect)] = []
    for (word, box) in words {
      if let last = out.last, abs(last.1.midY - box.midY) < 0.5 * min(last.1.height, box.height) {
        out[out.count - 1] = (last.0 + " " + word, last.1.union(box))
      } else {
        out.append((word, box))
      }
    }
    return out
  }
}

extension CGImagePropertyOrientation {
  init(_ o: UIImage.Orientation) {
    switch o {
    case .up: self = .up
    case .down: self = .down
    case .left: self = .left
    case .right: self = .right
    case .upMirrored: self = .upMirrored
    case .downMirrored: self = .downMirrored
    case .leftMirrored: self = .leftMirrored
    case .rightMirrored: self = .rightMirrored
    @unknown default: self = .up
    }
  }
}
