import Foundation

// MARK: - 索引

/// 信号索引摘要（一对象一文件 + index 的「index」）。
struct MarketSignalIndex: Codable, Hashable, Sendable {
    struct Entry: Codable, Hashable, Sendable {
        let id: UUID
        let dedupKey: String
        let subjectCode: String?
        let subjectName: String
        let direction: CanonicalDecisionType
        let status: SignalStatus
        let createdAt: String
        let reviewDueAt: String
        let outcome: SignalSettlement.Outcome?
    }

    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var entries: [Entry]

    init(schemaVersion: Int = MarketSignalIndex.currentSchemaVersion, entries: [Entry] = []) {
        self.schemaVersion = schemaVersion
        self.entries = entries
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        entries = try c.decodeIfPresent([Entry].self, forKey: .entries) ?? []
    }
}

// MARK: - Store

/// 信号持久化：`market-signals/{id}.json` 一对象一文件 + `index.json` 摘要，原子写。
/// 遵循仓库「高频追加对象用一对象一文件 + index 摘要」约定（无 SQLite）。
struct MarketSignalStore {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let baseDirectory: URL

    init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    // MARK: - 路径

    private var indexFile: URL {
        baseDirectory.appendingPathComponent("index.json")
    }

    private func signalFile(_ id: UUID) -> URL {
        baseDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    // MARK: - 读

    func loadIndex() -> MarketSignalIndex {
        guard let data = try? Data(contentsOf: indexFile),
              let index = try? decoder.decode(MarketSignalIndex.self, from: data)
        else { return MarketSignalIndex() }
        return index
    }

    func loadAll() -> [MarketDecisionSignal] {
        let index = loadIndex()
        return index.entries.compactMap { entry in
            loadSignal(id: entry.id)
        }
    }

    func loadSignal(id: UUID) -> MarketDecisionSignal? {
        guard let data = try? Data(contentsOf: signalFile(id)) else { return nil }
        return try? decoder.decode(MarketDecisionSignal.self, from: data)
    }

    func activeSignals() -> [MarketDecisionSignal] {
        loadAll().filter { $0.status == .active }
    }

    // MARK: - 写

    func save(_ signal: MarketDecisionSignal) throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try atomicWrite(encoder.encode(signal), to: signalFile(signal.id))
        try upsertIndexEntry(for: signal)
    }

    func saveAll(_ signals: [MarketDecisionSignal]) throws {
        guard !signals.isEmpty else { return }
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        var index = loadIndex()
        var byID: [UUID: MarketSignalIndex.Entry] = Dictionary(uniqueKeysWithValues: index.entries.map { ($0.id, $0) })
        for signal in signals {
            try atomicWrite(encoder.encode(signal), to: signalFile(signal.id))
            byID[signal.id] = Self.indexEntry(for: signal)
        }
        index.entries = byID.values.sorted { $0.createdAt > $1.createdAt }
        try atomicWrite(encoder.encode(index), to: indexFile)
    }

    func rebuildIndex(from signals: [MarketDecisionSignal]) throws {
        let index = MarketSignalIndex(
            entries: signals.map { Self.indexEntry(for: $0) }.sorted { $0.createdAt > $1.createdAt }
        )
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try atomicWrite(encoder.encode(index), to: indexFile)
    }

    private func upsertIndexEntry(for signal: MarketDecisionSignal) throws {
        var index = loadIndex()
        let entry = Self.indexEntry(for: signal)
        if let position = index.entries.firstIndex(where: { $0.id == entry.id }) {
            index.entries[position] = entry
        } else {
            index.entries.insert(entry, at: 0)
        }
        try atomicWrite(encoder.encode(index), to: indexFile)
    }

    static func indexEntry(for signal: MarketDecisionSignal) -> MarketSignalIndex.Entry {
        MarketSignalIndex.Entry(
            id: signal.id,
            dedupKey: signal.dedupKey,
            subjectCode: signal.subjectCode,
            subjectName: signal.subjectName,
            direction: signal.direction,
            status: signal.status,
            createdAt: signal.createdAt,
            reviewDueAt: signal.reviewDueAt,
            outcome: signal.settlement?.outcome
        )
    }

    // MARK: - 原子写

    private func atomicWrite(_ data: Data, to url: URL) throws {
        let tmpURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: tmpURL, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmpURL)
    }
}
