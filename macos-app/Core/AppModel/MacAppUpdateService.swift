#if os(macOS)
import AppKit
import Foundation

/// macOS implementation of `AppUpdateService`: queries the GitHub Release feed
/// via `AppUpdateChecker` and installs in place via `AppSelfUpdater`.
@MainActor
final class macOSAppUpdateService: AppUpdateService {
    private let checker: AppUpdateChecker

    init() throws {
        self.checker = try AppUpdateChecker()
    }

    var currentVersion: String { checker.currentVersion }

    func checkForUpdate() async throws -> AppUpdateRelease? {
        try await checker.check()
    }

    func install(release: AppUpdateRelease,
                 progress: @MainActor @escaping (_ message: String, _ downloadFraction: Double) -> Void) async throws {
        try await AppSelfUpdater.downloadAndPrepareInstall(
            release: release,
            progress: { message in
                // Map the macOS phase message into the cross-platform callback.
                // Fraction is 0 outside the download phase (extracting/validating/installing).
                progress(message, 0)
            },
            downloadProgress: { download in
                progress("正在下载… \(download.percentText)  \(download.sizeText)", download.fraction)
            }
        )
    }

    func openUpdateDestination(for release: AppUpdateRelease) {
        NSWorkspace.shared.open(release.htmlURL)
    }
}
#endif
