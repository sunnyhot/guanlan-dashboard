#if os(macOS)
import Foundation

struct LaunchAtLoginAgent {
    static let label = "com.sunnyhot.qieman.manager.dashboard.launch-at-login"

    let agentDirectoryURL: URL
    let appBundleURL: URL

    init(
        agentDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true),
        appBundleURL: URL = Bundle.main.bundleURL
    ) {
        self.agentDirectoryURL = agentDirectoryURL
        self.appBundleURL = appBundleURL
    }

    var plistURL: URL {
        agentDirectoryURL.appendingPathComponent("\(Self.label).plist", isDirectory: false)
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    func install() throws {
        try FileManager.default.createDirectory(
            at: agentDirectoryURL,
            withIntermediateDirectories: true
        )
        try plistData().write(to: plistURL, options: .atomic)
    }

    func uninstall() throws {
        guard isInstalled else { return }
        try FileManager.default.removeItem(at: plistURL)
    }

    func plistData() throws -> Data {
        let payload: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [
                "/usr/bin/open",
                appBundleURL.path
            ],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua"
        ]
        return try PropertyListSerialization.data(
            fromPropertyList: payload,
            format: .xml,
            options: 0
        )
    }
}
#endif
