import AppKit
import SwiftUI

@MainActor
enum MenuBarIcon {
    static let fallbackSystemName = "display"

    static func image(from url: URL?) -> NSImage? {
        guard let url,
              url.isFileURL,
              let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
              ]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? 0) > 0,
              let image = NSImage(contentsOf: url),
              image.size.width > 0,
              image.size.height > 0 else {
            return nil
        }
        image.isTemplate = true
        return image
    }

    static func image(bundle: Bundle = .main) -> NSImage? {
        image(from: bundle.url(forResource: "MenuBarIcon", withExtension: "pdf"))
    }
}

struct MenuBarIconLabel: View {
    var body: some View {
        Group {
            if let image = MenuBarIcon.image() {
                Image(nsImage: image)
            } else {
                Image(systemName: MenuBarIcon.fallbackSystemName)
            }
        }
        .accessibilityLabel("ScreenClear")
    }
}
