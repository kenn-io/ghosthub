import Foundation

enum UIResources {
    nonisolated static let bundle: Bundle = {
        if let packagedBundle = packagedBundle(
            applicationBundleURL: Bundle.main.bundleURL
        ) {
            return packagedBundle
        }

        return Bundle.module
    }()

    static func packagedBundle(
        applicationBundleURL: URL
    ) -> Bundle? {
        guard applicationBundleURL.pathExtension == "app" else {
            return nil
        }

        return Bundle(
            url: applicationBundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent(
                    "Ghosthub_GhosthubUI.bundle",
                    isDirectory: true
                )
        )
    }
}
