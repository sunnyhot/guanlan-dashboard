#if os(macOS)
import Foundation

enum AppSelfUpdateError: LocalizedError {
    case missingPackageAsset
    case unsupportedInstallLocation
    case extractionFailed
    case appBundleNotFound
    case invalidDownloadedBundle(String)
    case downloadedVersionNotNewer(String)
    case codeSignatureFailed(String)
    case installerLaunchFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingPackageAsset:
            return "这个 Release 没有可安装的 App 压缩包。"
        case .unsupportedInstallLocation:
            return "当前运行的不是 .app 包，无法自动覆盖安装。"
        case .extractionFailed:
            return "更新包解压失败。"
        case .appBundleNotFound:
            return "更新包里没有找到 QiemanDashboard.app。"
        case .invalidDownloadedBundle(let reason):
            return "更新包校验失败：\(reason)"
        case .downloadedVersionNotNewer(let version):
            return "下载到的版本 \(version) 不高于当前版本。"
        case .codeSignatureFailed(let detail):
            return "更新包签名校验失败：\(detail)"
        case .installerLaunchFailed(let detail):
            return "启动安装器失败：\(detail)"
        }
    }
}

// MARK: - Download Progress Reporting

struct AppSelfUpdateDownloadProgress: Sendable {
    let bytesReceived: Int64
    let totalBytes: Int64
    let fraction: Double

    var percentText: String {
        String(format: "%.0f%%", fraction * 100)
    }

    var sizeText: String {
        let received = ByteCountFormatter.string(fromByteCount: bytesReceived, countStyle: .file)
        if totalBytes > 0 {
            let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            return "\(received) / \(total)"
        }
        return received
    }
}

// MARK: - AppSelfUpdater

struct AppSelfUpdater {
    typealias ProgressHandler = @MainActor (String) -> Void
    typealias DownloadProgressHandler = @MainActor (AppSelfUpdateDownloadProgress) -> Void

    static func downloadAndPrepareInstall(
        release: AppUpdateRelease,
        progress: ProgressHandler,
        downloadProgress: DownloadProgressHandler? = nil
    ) async throws {
        guard let asset = release.asset else {
            throw AppSelfUpdateError.missingPackageAsset
        }

        let currentAppURL = Bundle.main.bundleURL
        guard currentAppURL.pathExtension == "app" else {
            throw AppSelfUpdateError.unsupportedInstallLocation
        }

        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("qieman-dashboard-update-\(UUID().uuidString)", isDirectory: true)
        let archiveURL = workDirectory.appendingPathComponent(asset.name)
        let extractDirectory = workDirectory.appendingPathComponent("expanded", isDirectory: true)

        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: extractDirectory, withIntermediateDirectories: true)

        await progress("正在下载 \(asset.name)…")
        let downloadedURL = try await downloadFile(
            from: asset.downloadURL,
            expectedSize: Int64(asset.size),
            downloadProgress: downloadProgress
        )
        if FileManager.default.fileExists(atPath: archiveURL.path) {
            try FileManager.default.removeItem(at: archiveURL)
        }
        try FileManager.default.moveItem(at: downloadedURL, to: archiveURL)

        await progress("正在解压更新包…")
        try runProcess("/usr/bin/ditto", arguments: ["-x", "-k", archiveURL.path, extractDirectory.path])

        await progress("正在校验应用包…")
        let downloadedAppURL = try findAppBundle(in: extractDirectory)
        try validate(downloadedAppURL: downloadedAppURL, release: release)
        try verifyCodeSignature(at: downloadedAppURL)

        await progress("正在准备替换当前应用并重启…")
        try launchInstallerScript(
            currentAppURL: currentAppURL,
            downloadedAppURL: downloadedAppURL,
            workDirectory: workDirectory
        )
    }

    // MARK: - Download with Progress

    private static func downloadFile(
        from url: URL,
        expectedSize: Int64,
        downloadProgress: DownloadProgressHandler?
    ) async throws -> URL {
        let delegate = DownloadDelegate(expectedSize: expectedSize, progressHandler: downloadProgress)
        // Use a delegate-based session (no completion handler on the task) so that
        // URLSessionDownloadDelegate progress callbacks are actually invoked.
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    // MARK: - URLSession Download Delegate

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
        let expectedSize: Int64
        let progressHandler: DownloadProgressHandler?
        var continuation: CheckedContinuation<URL, Error>?

        init(expectedSize: Int64, progressHandler: DownloadProgressHandler?) {
            self.expectedSize = expectedSize
            self.progressHandler = progressHandler
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedSize
            let fraction = total > 0 ? Double(totalBytesWritten) / Double(total) : 0
            let progress = AppSelfUpdateDownloadProgress(
                bytesReceived: totalBytesWritten,
                totalBytes: total,
                fraction: min(fraction, 1.0)
            )
            guard let handler = progressHandler else { return }
            Task { @MainActor in
                handler(progress)
            }
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
            // Move the temp file to a stable location before the system deletes it.
            let stableURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("qieman-download-\(UUID().uuidString)")
            do {
                try FileManager.default.moveItem(at: location, to: stableURL)
                continuation?.resume(returning: stableURL)
            } catch {
                continuation?.resume(throwing: error)
            }
            continuation = nil
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: Error?
        ) {
            if let error {
                continuation?.resume(throwing: error)
                continuation = nil
            }
        }
    }

    // MARK: - Validation & Install

    private static func findAppBundle(in directory: URL) throws -> URL {
        let directURL = directory.appendingPathComponent("QiemanDashboard.app", isDirectory: true)
        if FileManager.default.fileExists(atPath: directURL.path) {
            return directURL
        }

        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw AppSelfUpdateError.appBundleNotFound
        }

        for case let url as URL in enumerator where url.pathExtension == "app" {
            return url
        }
        throw AppSelfUpdateError.appBundleNotFound
    }

    private static func validate(downloadedAppURL: URL, release: AppUpdateRelease) throws {
        let infoPlistURL = downloadedAppURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: infoPlistURL)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dictionary = plist as? [String: Any] else {
            throw AppSelfUpdateError.invalidDownloadedBundle("Info.plist 格式异常")
        }

        let currentBundleID = Bundle.main.bundleIdentifier ?? "com.sunnyhot.qieman.manager.dashboard"
        let downloadedBundleID = dictionary["CFBundleIdentifier"] as? String
        guard downloadedBundleID == currentBundleID else {
            throw AppSelfUpdateError.invalidDownloadedBundle("Bundle ID 不匹配")
        }

        let downloadedVersion = dictionary["CFBundleShortVersionString"] as? String ?? ""
        guard AppUpdateChecker.compareVersions(downloadedVersion, release.currentVersion) == .orderedDescending else {
            throw AppSelfUpdateError.downloadedVersionNotNewer(downloadedVersion)
        }

        let executableName = dictionary["CFBundleExecutable"] as? String ?? "QiemanDashboard"
        let executableURL = downloadedAppURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(executableName)
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw AppSelfUpdateError.invalidDownloadedBundle("缺少可执行文件")
        }
    }

    private static func verifyCodeSignature(at appURL: URL) throws {
        do {
            try runProcess(
                "/usr/bin/codesign",
                arguments: ["--verify", "--deep", "--strict", "--verbose=2", appURL.path]
            )
        } catch {
            throw AppSelfUpdateError.codeSignatureFailed(error.localizedDescription)
        }
    }

    private static func launchInstallerScript(
        currentAppURL: URL,
        downloadedAppURL: URL,
        workDirectory: URL
    ) throws {
        let scriptURL = workDirectory.appendingPathComponent("install-update.sh")
        let script = """
        #!/bin/sh
        set -eu

        APP_PATH="$1"
        NEW_APP_PATH="$2"
        APP_PID="$3"
        WORK_DIR="$4"
        BACKUP_PATH="${APP_PATH}.previous-update"
        LOG_PATH="${WORK_DIR}/install.log"

        {
          echo "Preparing to replace ${APP_PATH}"
          attempts=0
          while kill -0 "${APP_PID}" 2>/dev/null; do
            attempts=$((attempts + 1))
            if [ "${attempts}" -gt 300 ]; then
              echo "Timed out waiting for app process to quit"
              exit 1
            fi
            sleep 0.2
          done

          rm -rf "${BACKUP_PATH}"
          if [ -e "${APP_PATH}" ]; then
            mv "${APP_PATH}" "${BACKUP_PATH}"
          fi

          if /usr/bin/ditto "${NEW_APP_PATH}" "${APP_PATH}"; then
            /usr/bin/xattr -dr com.apple.quarantine "${APP_PATH}" 2>/dev/null || true
            attempts=0
            until /usr/bin/open -n "${APP_PATH}"; do
              attempts=$((attempts + 1))
              if [ "${attempts}" -gt 20 ]; then
                echo "Timed out trying to relaunch updated app"
                exit 1
              fi
              sleep 0.5
            done
            rm -rf "${BACKUP_PATH}"
            rm -rf "${WORK_DIR}"
          else
            echo "Install failed; restoring previous app"
            rm -rf "${APP_PATH}"
            if [ -e "${BACKUP_PATH}" ]; then
              mv "${BACKUP_PATH}" "${APP_PATH}"
              /usr/bin/open -n "${APP_PATH}" || true
            fi
            exit 1
          fi
        } >>"${LOG_PATH}" 2>&1
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        process.arguments = [
            "/bin/sh",
            scriptURL.path,
            currentAppURL.path,
            downloadedAppURL.path,
            "\(ProcessInfo.processInfo.processIdentifier)",
            workDirectory.path,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw AppSelfUpdateError.installerLaunchFailed(error.localizedDescription)
        }
    }

    @discardableResult
    private static func runProcess(_ executablePath: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw AppSelfUpdateError.installerLaunchFailed(stderr.isEmpty ? stdout : stderr)
        }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
