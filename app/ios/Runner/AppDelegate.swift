import Flutter
import UIKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let registrar = registrar(forPlugin: "ClipRelayPasteButton") {
      let channel = FlutterMethodChannel(name: "cliprelay/paste", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        if call.method == "isSupported" {
          if #available(iOS 16.0, *) { result(true) } else { result(false) }
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
      registrar.register(PasteButtonFactory(channel: channel), withId: "cliprelay/paste_button")
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

final class PasteButtonFactory: NSObject, FlutterPlatformViewFactory {
  private let channel: FlutterMethodChannel

  init(channel: FlutterMethodChannel) {
    self.channel = channel
  }

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    if #available(iOS 16.0, *) {
      return PasteButtonView(frame: frame, channel: channel)
    }
    return EmptyPlatformView()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }
}

final class EmptyPlatformView: NSObject, FlutterPlatformView {
  func view() -> UIView { UIView() }
}

@available(iOS 16.0, *)
final class PasteTargetView: UIView {
  var onPaste: (([NSItemProvider]) -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [
      UTType.image.identifier, UTType.url.identifier, UTType.plainText.identifier, UTType.text.identifier,
    ])
  }

  required init?(coder: NSCoder) { nil }

  override func paste(itemProviders: [NSItemProvider]) {
    onPaste?(itemProviders)
  }
}

@available(iOS 16.0, *)
final class PasteButtonView: NSObject, FlutterPlatformView {
  private let container: PasteTargetView
  private let channel: FlutterMethodChannel

  init(frame: CGRect, channel: FlutterMethodChannel) {
    self.channel = channel
    container = PasteTargetView(frame: frame)
    super.init()
    let configuration = UIPasteControl.Configuration()
    configuration.displayMode = .iconAndLabel
    configuration.cornerStyle = .capsule
    let control = UIPasteControl(configuration: configuration)
    control.target = container
    control.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(control)
    NSLayoutConstraint.activate([
      control.centerXAnchor.constraint(equalTo: container.centerXAnchor),
      control.centerYAnchor.constraint(equalTo: container.centerYAnchor),
      control.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor),
      control.heightAnchor.constraint(lessThanOrEqualTo: container.heightAnchor),
    ])
    container.onPaste = { [weak self] providers in self?.handle(providers) }
  }

  func view() -> UIView { container }

  private func send(_ payload: [String: Any]) {
    DispatchQueue.main.async { self.channel.invokeMethod("pasted", arguments: payload) }
  }

  private func handle(_ providers: [NSItemProvider]) {
    guard let provider = providers.first else { return send([:]) }
    if provider.canLoadObject(ofClass: UIImage.self) {
      provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
        guard let image = object as? UIImage, let data = image.pngData() else {
          self?.send([:])
          return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("paste-\(UUID().uuidString).png")
        do {
          try data.write(to: url)
          self?.send(["imagePath": url.path])
        } catch {
          self?.send([:])
        }
      }
    } else if provider.canLoadObject(ofClass: URL.self) && !provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
      _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in self?.send(["text": url?.absoluteString ?? ""]) }
    } else {
      _ = provider.loadObject(ofClass: String.self) { [weak self] text, _ in self?.send(["text": text ?? ""]) }
    }
  }
}
