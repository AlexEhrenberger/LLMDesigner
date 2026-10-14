import Foundation

extension Bundle {
    /// SwiftPM's generated `Bundle.module` only looks for the resource bundle in the root of the
    /// .app, where codesign rejects extra content ("unsealed contents present in the bundle root").
    /// Look in Contents/Resources first and fall back to `Bundle.module` for `swift run`.
    static let swiftMathResources: Bundle = {
        let name = "SwiftMath_SwiftMath.bundle"
        for base in [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap({ $0 }) {
            if let bundle = Bundle(url: base.appendingPathComponent(name)) { return bundle }
        }
        return Bundle.module
    }()
}
