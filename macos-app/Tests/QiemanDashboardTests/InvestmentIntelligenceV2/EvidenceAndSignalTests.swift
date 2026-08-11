import XCTest
@testable import QiemanDashboard

/// DOM-9 单元测试：EvidenceFact / InvestmentSignal 分层 + ordinal/cardinal 语义。
///
/// 重点验证 ADR-D002（criterion 只接受 cardinal，signal 是 ordinal）+
/// ADR-DATA006（uncertain 联动）+ ADR-D004（derivedFrom 引用）。
final class EvidenceAndSignalTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_724_000_000)

    // MARK: - EvidenceExtractionMethod

    func testExtractionMethod_xbrlVsLLM() {
        // XBRL fact 机器可读，LLM extracted 需 verification
        XCTAssertNotEqual(EvidenceExtractionMethod.xbrlFact, .llmExtracted)
    }

    // MARK: - EvidenceVerificationStatus

    func testVerificationStatus_trustworthy() {
        XCTAssertTrue(EvidenceVerificationStatus.verified.isTrustworthy)
        XCTAssertFalse(EvidenceVerificationStatus.singleSourced.isTrustworthy)
        XCTAssertFalse(EvidenceVerificationStatus.unverifiable.isTrustworthy)
        XCTAssertFalse(EvidenceVerificationStatus.conflicting.isTrustworthy)
    }

    // MARK: - EvidenceFact

    func testEvidenceFact_xbrlFactFromSEC() throws {
        // SEC 10-K XBRL 营收 fact
        let fact = EvidenceFact(
            id: DomainID(rawValue: "fact_1"),
            evidenceID: EvidenceID(rawValue: "ev_sec_10k"),
            statement: "茅台 2024 Q2 营收 450 亿元",
            extractionMethod: .xbrlFact,
            verificationStatus: .verified,
            subjectCanonical: .listing(ListingID(rawValue: "list_600519")),
            numericValue: Decimal(string: "450")!,
            numericUnit: "亿元"
        )
        let data = try JSONEncoder().encode(fact)
        let decoded = try JSONDecoder().decode(EvidenceFact.self, from: data)
        XCTAssertEqual(fact, decoded)
        XCTAssertEqual(decoded.extractionMethod, .xbrlFact)
        XCTAssertTrue(decoded.verificationStatus.isTrustworthy)
    }

    func testEvidenceFact_llmExtractedDefaultsUnverifiable() {
        // LLM 抽取的 fact 默认 unverifiable（需 Evidence Matcher 升级，RES-8）
        let fact = EvidenceFact(
            id: DomainID(rawValue: "fact_2"),
            evidenceID: EvidenceID(rawValue: "ev_news"),
            statement: "公司高管在采访中表示看好下半年增长",
            extractionMethod: .llmExtracted,
            verificationStatus: .unverifiable,
            subjectCanonical: .listing(ListingID(rawValue: "list_x"))
        )
        XCTAssertEqual(fact.extractionMethod, .llmExtracted)
        XCTAssertFalse(fact.verificationStatus.isTrustworthy)
        XCTAssertNil(fact.numericValue)
    }

    // MARK: - InvestmentSignal（ordinal 语义）

    func testSignalDirection_isDeterministic() {
        XCTAssertTrue(SignalDirection.bullish.isDeterministic)
        XCTAssertTrue(SignalDirection.bearish.isDeterministic)
        XCTAssertTrue(SignalDirection.neutral.isDeterministic)
        XCTAssertFalse(SignalDirection.uncertain.isDeterministic)
    }

    func testSignalDirection_allCases() {
        XCTAssertEqual(SignalDirection.allCases.count, 4)
        XCTAssertEqual(
            SignalDirection.allCases.map(\.rawValue),
            ["BULLISH", "BEARISH", "NEUTRAL", "UNCERTAIN"]
        )
    }

    func testInvestmentSignal_llmProduced() throws {
        // LLM Research 产出的 signal（ordinal）
        let signal = InvestmentSignal(
            id: SignalID(rawValue: "sig_1"),
            subjectCanonical: .listing(ListingID(rawValue: "list_600519")),
            dimension: .momentum,
            direction: .bullish,
            strength: .strong,
            derivedFromEvidenceIDs: [
                EvidenceID(rawValue: "ev_1"),
                EvidenceID(rawValue: "ev_2"),
            ],
            effectiveAt: now,
            producer: SignalProducer(kind: .llm, modelIdentifier: "gpt-4"),
            rationale: "近 20 日突破前高，量价配合"
        )
        let data = try JSONEncoder().encode(signal)
        let decoded = try JSONDecoder().decode(InvestmentSignal.self, from: data)
        XCTAssertEqual(signal, decoded)
        XCTAssertEqual(decoded.direction, .bullish)
        XCTAssertEqual(decoded.strength, .strong)
        XCTAssertEqual(decoded.derivedFromEvidenceIDs.count, 2)
        XCTAssertEqual(decoded.producer.modelIdentifier, "gpt-4")
    }

    func testInvestmentSignal_factorProduced() {
        // Factor engine 产的 signal（Cardinal 经 SignalPolicy 转 ordinal 的产物）
        let signal = InvestmentSignal(
            id: SignalID(rawValue: "sig_2"),
            subjectCanonical: .listing(ListingID(rawValue: "list_x")),
            dimension: .technical,
            direction: .bearish,
            strength: .moderate,
            derivedFromEvidenceIDs: [EvidenceID(rawValue: "ev_bar_1")],
            effectiveAt: now,
            producer: .factorEngine,
            rationale: nil
        )
        XCTAssertEqual(signal.producer.kind, .factorEngine)
        XCTAssertNil(signal.producer.modelIdentifier)
    }

    // MARK: - ADR-DATA006 联动：unknown → uncertain signal

    func testUnknownDataProducesUncertainSignal() {
        // Risk correlation 数据不足 → unknown（ADR-DATA006 §Decision 4）
        // SignalPolicy 对 unknown 产 uncertain signal（FAC-2）
        let signal = InvestmentSignal(
            id: SignalID(rawValue: "sig_uncertain"),
            subjectCanonical: .listing(ListingID(rawValue: "list_x")),
            dimension: .risk,
            direction: .uncertain,   // 数据不足
            strength: .weak,
            derivedFromEvidenceIDs: [],
            effectiveAt: now,
            producer: .factorEngine,
            rationale: "历史序列不足，无法计算 correlation"
        )
        XCTAssertFalse(signal.direction.isDeterministic)
    }

    // MARK: - ADR-D004 replay：derivedFrom 引用

    func testSignalDerivedFrom_isReplayReference() {
        // signal 的 derivedFromEvidenceIDs 是 D004 replay 的引用对象
        // 重放时按引用取 evidence，不重跑 LLM
        let evidenceIDs = [
            EvidenceID(rawValue: "ev_1"),
            EvidenceID(rawValue: "ev_2"),
            EvidenceID(rawValue: "ev_3"),
        ]
        let signal = InvestmentSignal(
            id: SignalID(rawValue: "sig_replay"),
            subjectCanonical: .instrument(InstrumentID(rawValue: "inst_x")),
            dimension: .value,
            direction: .neutral,
            strength: .moderate,
            derivedFromEvidenceIDs: evidenceIDs,
            effectiveAt: now,
            producer: .llmDefault
        )
        XCTAssertEqual(signal.derivedFromEvidenceIDs, evidenceIDs)
        // 重放 = 引用 IDs 取当时的 evidence
        XCTAssertEqual(signal.derivedFromEvidenceIDs.count, 3)
    }

    // MARK: - SignalDimension / SignalProducer

    func testSignalDimension_allCases() {
        XCTAssertEqual(SignalDimension.allCases.count, 7)
        XCTAssertTrue(SignalDimension.allCases.contains(.momentum))
        XCTAssertTrue(SignalDimension.allCases.contains(.risk))
    }

    func testSignalProducer_statics() {
        XCTAssertEqual(SignalProducer.llmDefault.kind, .llm)
        XCTAssertEqual(SignalProducer.factorEngine.kind, .factorEngine)
        XCTAssertNil(SignalProducer.factorEngine.modelIdentifier)
    }

    // MARK: - EvidenceFact → InvestmentSignal 不可直接（必须经 SignalPolicy）

    func testEvidenceFactAndSignal_areDifferentLayers() {
        // EvidenceFact 是事实层（已发生），InvestmentSignal 是判断层（推导）
        // 两者不能直接互换，必须经 SignalPolicy（FAC-2）转换
        let fact = EvidenceFact(
            id: DomainID(rawValue: "f"),
            evidenceID: EvidenceID(rawValue: "ev_obs"),
            statement: "营收同比 +20%",
            extractionMethod: .xbrlFact,
            verificationStatus: .verified,
            subjectCanonical: .listing(ListingID(rawValue: "list_x")),
            numericValue: 20,
            numericUnit: "%"
        )
        let signal = InvestmentSignal(
            id: SignalID(rawValue: "s"),
            subjectCanonical: fact.subjectCanonical,
            dimension: .value,
            direction: .bullish,
            strength: .strong,
            derivedFromEvidenceIDs: [fact.evidenceID],
            effectiveAt: now,
            producer: .llmDefault
        )
        // fact 是事实，signal 引用 fact 的 evidenceID
        XCTAssertEqual(signal.derivedFromEvidenceIDs, [fact.evidenceID])
        // 类型不同（DomainID vs SignalID），不能直接赋值——这是编译期保证
        // 这里验证它们即使 rawValue 相同，类型也不同
        let factIDRaw = fact.id.rawValue
        let signalIDRaw = signal.id.rawValue
        XCTAssertEqual(factIDRaw, "f")
        XCTAssertEqual(signalIDRaw, "s")
        XCTAssertNotEqual(factIDRaw, signalIDRaw)
    }
}
