import AppIntents
import ReachyWidgetUI

/// The same declaration in the app bundle: Apple resolves shortcuts and entity
/// queries from the main bundle, so its metadata has to name the package too.
struct ReachyMiniIntentsPackage: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] {
        [ReachyWidgetIntentsPackage.self]
    }
}
