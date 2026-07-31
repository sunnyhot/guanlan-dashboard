import Foundation

// MARK: - AppUpdateService

/// Cross-platform application update abstraction.
///
/// The macOS app downloads & installs GitHub Release assets in place
/// (`macOSAppUpdateService` wrapping `AppUpdateChecker` + `AppSelfUpdater`).
/// The iOS app ships via App Store / TestFlight and therefore hides in-app
/// updates entirely on first launch (`iOSAppUpdateService` is a no-op).
///
/// Consumers (`AppModel/Update.swift`) depend only on this protocol so the
/// shared code compiles on both platforms without `#if os()` scattered around.
@MainActor
protocol AppUpdateService: AnyObject {
    /// The human-readable version string of the currently running build.
    var currentVersion: String { get }

    /// Whether this platform can download and install an update in place.
    /// macOS: true. iOS: false (updates come from the App Store).
    var supportsAutoInstall: Bool { get }

    /// Check the update feed for a newer release. Returns nil when up-to-date.
    func checkForUpdate() async throws -> AppUpdateRelease?

    /// Download and install `release` in place.
    /// - Parameters:
    ///   - progress: main-actor callback with a status message and download
    ///     fraction in 0...1 (0 outside the download phase).
    func install(release: AppUpdateRelease,
                 progress: @MainActor @escaping (_ message: String, _ downloadFraction: Double) -> Void) async throws

    /// Open the platform-appropriate destination for manual update
    /// (GitHub Release page on macOS; App Store product page on iOS).
    func openUpdateDestination(for release: AppUpdateRelease)
}

// MARK: - Platform Factory

/// Construct the platform-default update service.
/// macOS: GitHub Release self-update. iOS: App Store (no-op in-app).
@MainActor
func makeDefaultAppUpdateService() -> any AppUpdateService {
    #if os(macOS)
    if let service = try? macOSAppUpdateService() {
        return service
    }
    // Fallback if AppUpdateChecker init fails (e.g. unreadable bundle).
    return NoOpAppUpdateService()
    #elseif os(iOS)
    return iOSAppUpdateService()
    #else
    return NoOpAppUpdateService()
    #endif
}

/// Fallback no-op used when the macOS checker cannot be constructed.
@MainActor
final class NoOpAppUpdateService: AppUpdateService {
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var supportsAutoInstall: Bool { false }

    func checkForUpdate() async throws -> AppUpdateRelease? { nil }

    func install(release: AppUpdateRelease,
                 progress: @MainActor @escaping (String, Double) -> Void) async throws {}

    func openUpdateDestination(for release: AppUpdateRelease) {}
}

