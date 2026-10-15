import Foundation
import AppKit

public enum AppArtwork {
    public static let bundle: Bundle = {
        if let url = Bundle.main.url(forResource: "SampleBrowser_SampleBrowserAssets", withExtension: "bundle"),
           let embedded = Bundle(url: url) {
            return embedded
        }
        return .module
    }()

    @MainActor public static let icon: NSImage = {
        guard let url = bundle.url(forResource: "AppIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return NSImage()
        }
        return image
    }()
}
