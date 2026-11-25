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
    return (request.results ?? []).compactMap { obs in
      guard let text = obs.topCandidates(1).first?.string else { return nil }
      // Vision measures from the bottom-left; the Dart side wants the top-left.
      let b = obs.boundingBox
      let dx = obs.bottomRight.x - obs.bottomLeft.x
      let dy = obs.bottomRight.y - obs.bottomLeft.y
      let slope = dx > 0 ? -Double(dy / dx) : 0
      return [
        "text": text,
        "minX": Double(b.minX), "minY": Double(1 - b.maxY),
        "maxX": Double(b.maxX), "maxY": Double(1 - b.minY),
        "slope": slope,
      ]
    }
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
