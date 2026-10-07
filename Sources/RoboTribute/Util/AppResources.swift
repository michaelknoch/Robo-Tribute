import Foundation

nonisolated enum AppResources {
    /// In the .app the resource bundle lives in Contents/Resources (the bundle root must stay sealed for code signing);
    /// `swift run` falls back to SwiftPM's build directory.
    static let bundle: Bundle = {
        if let url = Bundle.main.url(forResource: "RoboTribute_RoboTribute", withExtension: "bundle"), let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.module
    }()
}
