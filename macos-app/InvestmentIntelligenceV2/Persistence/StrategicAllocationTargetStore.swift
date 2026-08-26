import Foundation

// MARK: - StrategicAllocationTargetStore（用户战略目标 append-only 文件事实源）
//
// Target 是用户意图，不是可从 Provider spool 重放的派生行情数据（ADR-DATA004
// 的 spool 只覆盖行情事实）——因此不落可重建的 canonical.sqlite3，落 V2 工作
// 目录内的 user-intent 文件事实源：
//
// ```
// investment-intelligence-v2/
// └─ user-intent/
//    └─ allocation-targets/
//       ├─ <target-id>.json    # 不可变事件，一对象一文件
//       └─ current.json        # 当前 target 指针，原子替换
// ```
//
// 写入纪律（产品重构方案 §6.1）：
// 1. 只接受经 StrategicAllocationPolicy 两个 apply 方法构造的 AllocationTarget
//    （构造封闭保证），落盘前再过 validateCompleteCoverage 五类完备门禁。
// 2. 事件文件 atomic write 成功后，才原子更新 current 指针。
// 3. 同 ID 同内容幂等；同 ID 不同内容 fail-closed（拒绝覆盖历史）。
// 4. 不提供 update/delete；历史永久保留。
// 5. current 指针损坏时扫描合法事件按 createdAt + id 确定性恢复，记诊断日志。
// 6. 文件不包含任何 API Key（AllocationTarget 本身无凭据字段）。
//
// 升级兼容：旧链路「维持当前配置」自复制 Target 只存在于 artifact 内嵌，
// 永不写入本 Store——Dashboard 有效性过滤以「target ID 能在本 Store 历史中
// 解析」为准，旧 artifact 保留审计不冒充有效结论。

/// 战略目标事件 Store（无状态纯函数 + 文件系统）。
struct StrategicAllocationTargetStore: Sendable {

    /// 事件文件形态（一对象一文件）。
    struct Event: Sendable, Codable, Hashable {
        /// 事件 schema 版本（结构变更时递增，解码 fail-closed）。
        let schemaVersion: Int
        /// 完整 AllocationTarget（Codable 解码自带 Validator + ID 防伪门禁）。
        let target: AllocationTarget
        /// 被取代的 target ID（首个目标为 nil）。
        let supersedesTargetID: String?
        /// 用户可读的变更原因。
        let changeReason: String?
        /// 事件落盘时间（UTC 毫秒 ISO8601）。
        let recordedAt: Date
    }

    /// current 指针文件形态。
    struct CurrentPointer: Sendable, Codable, Hashable {
        let schemaVersion: Int
        let targetID: String
        let updatedAt: Date
    }

    enum StoreError: Error, Equatable, Sendable {
        /// 同 ID 不同内容（拒绝覆盖历史事件）。
        case idConflict(targetID: String)
        /// 事件文件损坏（解码失败 / schema 不识别）。
        case corruptEvent(fileName: String, detail: String)
        /// 指针指向不存在的事件。
        case danglingPointer(targetID: String)
        /// supersedes 声明与当前指针不一致。
        case supersedesMismatch(targetID: String, expectedCurrent: String?)
        /// 五类完备门禁（透传 Validator 形态）。
        case incompleteCoverage([AssetClass])
        /// 磁盘读写失败（原子写失败等）。
        case ioFailure(String)
    }

    static let schemaVersion = 1
    static let directoryName = "allocation-targets"
    static let userIntentDirectoryName = "user-intent"
    static let currentPointerFileName = "current.json"

    /// allocation-targets 目录（V2 工作目录派生）。
    let directory: URL

    /// - Parameter workDirectory: V2 工作目录（CanonicalStorePaths.workDirectory）。
    init(workDirectory: URL) {
        self.directory = workDirectory
            .appendingPathComponent(Self.userIntentDirectoryName, isDirectory: true)
            .appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    // MARK: - 写入（append-only）

    /// 记录新 target 事件并推进 current 指针。
    ///
    /// 纪律：事件文件写成功后才更新指针；同 ID 同内容幂等 no-op（指针缺失时
    /// 仍会补推进）；supersedes 必须精确等于当前指针（首事件为 nil）。
    @discardableResult
    func record(
        target: AllocationTarget,
        supersedesTargetID: String?,
        changeReason: String?,
        now: Date
    ) throws -> Event {
        do {
            try StrategicAllocationValidator().validateCompleteCoverage(entries: target.entries)
        } catch let error as StrategicAllocationValidator.ValidationError {
            if case let .missingAssetClasses(missing) = error {
                throw StoreError.incompleteCoverage(missing)
            }
            throw error
        }

        let current = try loadCurrentPointer()
        let event = Event(
            schemaVersion: Self.schemaVersion,
            target: target,
            supersedesTargetID: supersedesTargetID,
            changeReason: changeReason,
            recordedAt: now
        )

        // 同 ID 幂等 / 异内容 fail-closed（身份以 target 内容为准——ID 由
        // 内容派生；事件包装字段 recordedAt/changeReason 重放时容许不同）
        let eventURL = self.url(forTargetID: target.id.rawValue)
        if FileManager.default.fileExists(atPath: eventURL.path) {
            let existing = try loadEvent(at: eventURL)
            guard existing.target == target else {
                throw StoreError.idConflict(targetID: target.id.rawValue)
            }
        } else {
            guard current?.targetID == supersedesTargetID else {
                throw StoreError.supersedesMismatch(
                    targetID: target.id.rawValue,
                    expectedCurrent: current?.targetID
                )
            }
            try writeAtomic(Self.encode(event), to: eventURL)
        }

        // 指针推进（幂等：内容相同跳过）
        let pointer = CurrentPointer(
            schemaVersion: Self.schemaVersion,
            targetID: target.id.rawValue,
            updatedAt: now
        )
        if current != pointer {
            try writeAtomic(Self.encode(pointer), to: currentPointerURL)
        }
        return event
    }

    // MARK: - 读取

    /// 当前生效 target（无事件 → nil；指针损坏走确定性恢复）。
    func currentTarget() throws -> AllocationTarget? {
        try loadCurrentEvent()?.target
    }

    /// 当前事件（指针 → 事件；指针缺失/损坏时按 createdAt + id 确定性恢复）。
    func loadCurrentEvent() throws -> Event? {
        if let pointer = try? loadStrictCurrentPointer() {
            guard let event = try? event(forTargetID: pointer.targetID) else {
                throw StoreError.danglingPointer(targetID: pointer.targetID)
            }
            return event
        }
        // 指针缺失或损坏：扫描合法事件确定性恢复（最新 createdAt，并列取 id
        // 字典序大者——与恢复语义一致的双键排序）。
        let events = try history()
        return events.last
    }

    /// 全部合法事件（createdAt 升序，并列取 id 字典序——确定性）。
    func history() throws -> [Event] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        var events: [Event] = []
        for name in names.sorted() where name.hasSuffix(".json") && name != Self.currentPointerFileName {
            let url = directory.appendingPathComponent(name, isDirectory: false)
            do {
                events.append(try loadEvent(at: url))
            } catch {
                // 单个损坏事件不静默丢弃（fail-closed 语义留给点查路径）；
                // history 聚合面记录诊断并跳过，保证恢复流程可用。
                diagnosticLog("allocation-target 事件损坏已跳过: \(name) — \(error)")
            }
        }
        return events.sorted {
            $0.target.createdAt == $1.target.createdAt
                ? $0.target.id.rawValue < $1.target.id.rawValue
                : $0.target.createdAt < $1.target.createdAt
        }
    }

    /// 按 target ID 点查事件（不存在 → nil；损坏 → 抛错）。
    func event(forTargetID id: String) throws -> Event? {
        let url = url(forTargetID: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try loadEvent(at: url)
    }

    /// 合法 target ID 集合（Dashboard 有效性过滤用：artifact 内嵌 target
    /// 的 id 能解析到这里的才算「用户意图可溯」的有效结论）。
    func resolvableTargetIDs() throws -> Set<String> {
        Set(try history().map { $0.target.id.rawValue })
    }

    // MARK: - 私有

    private var currentPointerURL: URL {
        directory.appendingPathComponent(Self.currentPointerFileName, isDirectory: false)
    }

    private func url(forTargetID id: String) -> URL {
        directory.appendingPathComponent("\(id).json", isDirectory: false)
    }

    /// 指针严格读取：解码失败 / schema 不识别 → nil（触发恢复流程）。
    private func loadStrictCurrentPointer() throws -> CurrentPointer? {
        guard FileManager.default.fileExists(atPath: currentPointerURL.path) else {
            return nil
        }
        guard let pointer = try? decode(CurrentPointer.self, from: currentPointerURL),
              pointer.schemaVersion <= Self.schemaVersion else {
            diagnosticLog("current 指针损坏，进入确定性恢复")
            return nil
        }
        return pointer
    }

    /// 兼容性指针读取（供 record 的 supersedes 校验；损坏视为 nil）。
    private func loadCurrentPointer() throws -> CurrentPointer? {
        try loadStrictCurrentPointer()
    }

    private func loadEvent(at url: URL) throws -> Event {
        do {
            let event = try decode(Event.self, from: url)
            guard event.schemaVersion <= Self.schemaVersion else {
                throw StoreError.corruptEvent(
                    fileName: url.lastPathComponent,
                    detail: "schemaVersion \(event.schemaVersion) 高于本版本 \(Self.schemaVersion)")
            }
            return event
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.corruptEvent(
                fileName: url.lastPathComponent, detail: String(describing: error))
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        do {
            return try decoder.decode(T.self, from: Data(contentsOf: url))
        } catch DecodingError.dataCorrupted(let context) {
            // AllocationTarget 校验式解码会把 Validator / ID 防伪错误包成
            // dataCorrupted——fail-closed 透出上下文
            throw StoreError.corruptEvent(
                fileName: url.lastPathComponent,
                detail: context.debugDescription)
        }
    }

    private static func encode<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        // 确定性类型的编码失败 = 编程错误，fail-fast
        return try! encoder.encode(value)
    }

    private func writeAtomic(_ data: Data, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
        } catch {
            throw StoreError.ioFailure(String(describing: error))
        }
    }

    private func diagnosticLog(_ message: String) {
        Task {
            await AIAgentDiagnosticLog.record("allocation-target-store", message: message)
        }
    }
}
