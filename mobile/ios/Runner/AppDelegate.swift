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
    let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation)
    try handler.perform([request])
    // Width / height of the photo as Vision reads it (turned), for the row slope in Dart.
    let sideways: Set<CGImagePropertyOrientation> = [.left, .leftMirrored, .right, .rightMirrored]
    let aspect = sideways.contains(orientation)
      ? Double(cg.height) / Double(max(cg.width, 1)) : Double(cg.width) / Double(max(cg.height, 1))
    let observations = request.results ?? []
    let (lineHeight, pitch) = ReceiptOcr.lineSize(observations.map { $0.boundingBox })
    var pieces: [[String: Any]] = []
    for obs in observations {
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
      // Such a piece is taller than one line: that part of the photo is read again, one line at a
      // time. The lines are used only if together they give back the same text.
      var runs: [(String, CGRect)] = [(text, obs.boundingBox)]
      if let split = ReceiptOcr.reread(handler, request, obs.boundingBox, text, lineHeight, pitch) { runs = split }
      for run in runs {
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

  /// The usual height of one line of text, and the distance from one line to the next, both as
  /// parts of the photo's height. 0 when there are too few pieces to tell.
  static func lineSize(_ boxes: [CGRect]) -> (CGFloat, CGFloat) {
    guard boxes.count >= 3 else { return (0, 0) }
    let heights = boxes.map { $0.height }.sorted()
    let h = heights[heights.count / 2]
    let mids = boxes.filter { $0.height < 1.4 * h }.map { $0.midY }.sorted()
    var steps: [CGFloat] = []
    for i in 1..<max(mids.count, 1) where mids[i] - mids[i - 1] > 0.6 * h { steps.append(mids[i] - mids[i - 1]) }
    guard !steps.isEmpty else { return (h, 0) }
    steps.sort()
    // The smallest steps are next lines; bigger ones are blank space on the receipt.
    let pitch = steps[steps.count / 4]
    return (h, min(max(pitch, 1.05 * h), 3 * h))
  }

  /// A piece that covers several lines, read again line by line. nil when the piece is one line,
  /// or when the lines read again do not give back its text (for example big letters in a header).
  static func reread(
    _ handler: VNImageRequestHandler, _ first: VNRecognizeTextRequest, _ box: CGRect, _ text: String,
    _ lineHeight: CGFloat, _ pitch: CGFloat
  ) -> [(String, CGRect)]? {
    guard lineHeight > 0, pitch > 0, box.height > 1.6 * lineHeight else { return nil }
    let count = Int(((box.height - lineHeight) / pitch).rounded()) + 1
    guard count >= 2, count <= 12 else { return nil }
    var out: [(String, CGRect)] = []
    for i in 0..<count {
      // Vision measures from the bottom-left, so line 0 is at the top of the box.
      let mid = box.maxY - lineHeight / 2 - CGFloat(i) * pitch
      let core = (mid - pitch / 2)...(mid + pitch / 2)
      let pad = 0.6 * lineHeight
      let roi = CGRect(x: box.minX - 0.01, y: mid - lineHeight / 2 - pad, width: box.width + 0.02, height: lineHeight + 2 * pad)
        .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
      guard !roi.isNull, roi.width > 0, roi.height > 0 else { return nil }
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.usesLanguageCorrection = false
      request.recognitionLanguages = first.recognitionLanguages
      request.regionOfInterest = roi
      guard (try? handler.perform([request])) != nil else { return nil }
      var line: [(String, CGRect)] = []
      for obs in request.results ?? [] {
        guard let t = obs.topCandidates(1).first?.string, !t.isEmpty else { continue }
        // Boxes come back as parts of the region; turn them into parts of the photo.
        let r = obs.boundingBox
        let b = CGRect(
          x: roi.minX + r.minX * roi.width, y: roi.minY + r.minY * roi.height,
          width: r.width * roi.width, height: r.height * roi.height)
        if core.contains(b.midY) { line.append((t, b)) }
      }
      line.sort { $0.1.minX < $1.1.minX }
      out.append(contentsOf: line)
    }
    guard out.count >= 2 else { return nil }
    let again = out.map { $0.0 }.joined(separator: " ")
    return ReceiptOcr.similar(again, text) ? out : nil
  }

  /// Two texts are the same apart from a few letters (spaces and case do not count).
  static func similar(_ a: String, _ b: String) -> Bool {
    let x = Array(a.lowercased().filter { !$0.isWhitespace })
    let y = Array(b.lowercased().filter { !$0.isWhitespace })
    guard !x.isEmpty, !y.isEmpty else { return false }
    var row = Array(0...y.count)
    for i in 1...x.count {
      var prev = row[0]
      row[0] = i
      for j in 1...y.count {
        let keep = row[j]
        row[j] = x[i - 1] == y[j - 1] ? prev : 1 + min(prev, row[j], row[j - 1])
        prev = keep
      }
    }
    return Double(row[y.count]) <= 0.2 * Double(max(x.count, y.count))
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
