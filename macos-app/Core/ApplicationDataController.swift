import Foundation

enum ApplicationDataError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            return "应用数据目录不可用：\(message)"
        }
    }
}

/// Owns the app's local data directory. Network access is handled directly by
/// the native clients; no local HTTP service or scripting runtime is involved.
final class ApplicationDataController {
    private(set) var supportDirectory: URL?

    var logFileURL: URL? {
        supportDirectory?.appendingPathComponent("dashboard.log", isDirectory: false)
    }

    @discardableResult
    func prepareEnvironment() throws -> URL {
        let directory = try prepareSupportDirectory()
        supportDirectory = directory
        prepareLogFileIfNeeded(at: directory)
        return directory
    }

    func openDataDirectory() {
        guard let supportDirectory else { return }
        FilePresenter.reveal(supportDirectory)
    }

    private func prepareSupportDirectory() throws -> URL {
        let fileManager = FileManager.default
        let directory: URL

        if let customPath = UserDefaults.standard.string(forKey: AppStorageKey.customDataDirectory),
           !customPath.isEmpty {
            directory = URL(fileURLWithPath: customPath, isDirectory: true)
        } else {
            guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw ApplicationDataError.unavailable("无法定位 Application Support")
            }
            directory = appSupport.appendingPathComponent("QiemanDashboard", isDirectory: true)
        }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.createDirectory(
                at: directory.appendingPathComponent("output", isDirectory: true),
                withIntermediateDirectories: true
            )
        } catch {
            throw ApplicationDataError.unavailable(error.localizedDescription)
        }
        writeReadmeIfNeeded(at: directory)
        return directory
    }

    private func prepareLogFileIfNeeded(at directory: URL) {
        let logURL = directory.appendingPathComponent("dashboard.log", isDirectory: false)
        guard !FileManager.default.fileExists(atPath: logURL.path) else { return }
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
    }

    private func writeReadmeIfNeeded(at directory: URL) {
        let readme = directory.appendingPathComponent("README.txt", isDirectory: false)
        guard !FileManager.default.fileExists(atPath: readme.path) else { return }
        let text = """
        Qieman Dashboard App 数据目录

        - user-watchlist.json: 我的关注、关注起始价与每日价格记录
        - output/: 抓取输出与运行数据
        - dashboard.log: 应用运行日志
        - ai-analysis-logs/: 每次 AI 分析的完整 JSONL 诊断日志（自动轮转）
        """
        try? text.write(to: readme, atomically: true, encoding: .utf8)
    }
}
