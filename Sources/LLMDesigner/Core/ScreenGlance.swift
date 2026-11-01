import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

/// "Bildschirm betrachten" in the mini chat: a picture of a whole screen for models that see pictures (Gemma 4,
/// Qwen 3.5). macOS asks for the screen-recording permission once; it lives in System Settings › Privacy & Security.
enum ScreenGlance {
    enum Failure: LocalizedError {
        case noDisplay
        case encoding

        var errorDescription: String? {
            switch self {
            case .noDisplay: "Der Bildschirm wurde nicht gefunden."
            case .encoding: "Das Bildschirmfoto konnte nicht gespeichert werden."
            }
        }
    }

    /// Whether the app may record the screen. After the permission is given, macOS reports it only once the app
    /// has been started again.
    static var isAllowed: Bool { CGPreflightScreenCaptureAccess() }

    /// Asks for the permission; only the first time does macOS show its own dialog.
    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// System Settings at the screen-recording permission.
    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Pixels of the picture: the screen's own resolution, but no larger than the pictures the app sends anyway.
    static func pictureSize(points: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        let width = points.width * scale
        let height = points.height * scale
        let factor = min(1, CGFloat(AttachmentStore.maxPixelSize) / max(width, height, 1))
        return (max(1, Int((width * factor).rounded())), max(1, Int((height * factor).rounded())))
    }

    /// The display as PNG, without the window `excluded` (the mini chat itself) and without the mouse pointer.
    static func capture(display displayID: CGDirectDisplayID, excluding excluded: CGWindowID?) async throws -> Data {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw Failure.noDisplay }
        let filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { $0.windowID == excluded })
        let size = pictureSize(points: filter.contentRect.size, scale: CGFloat(filter.pointPixelScale))
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.showsCursor = false
        configuration.colorSpaceName = CGColorSpace.sRGB
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.encoding
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encoding }
        return data as Data
    }
}

extension NSScreen {
    /// The Core Graphics display the screen shows.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
