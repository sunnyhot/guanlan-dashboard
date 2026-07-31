#if os(iOS)
import Foundation

/// iOS implementation of `AppUpdateService`.
///
/// First TestFlight build strategy: **in-app update checks are hidden
/// entirely** — TestFlight/App Store own version updates. `checkForUpdate`
/// reports up-to-date, `install` is a no-op, and `openUpdateDestination` is a
/// no-op until an App Store product ID is wired in.
@MainActor
final class iOSAppUpdateService: AppUpdateService {
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var supportsAutoInstall: Bool { false }

    func checkForUpdate() async throws -> AppUpdateRelease? {
        // Updates are managed by the App Store; report up-to-date.
        nil
    }

    func install(release: AppUpdateRelease,
                 progress: @MainActor @escaping (String, Double) -> Void) async throws {
        // No in-place install on iOS.
    }

    func openUpdateDestination(for release: AppUpdateRelease) {
        // TODO: open App Store product page once an App Store ID is available.
    }
}
#endif
