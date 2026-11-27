import Foundation

/// 估值校准台账持久化（单 JSON 文件）。
struct FundEstimateCalibrationStore {
    func load(from fileURL: URL) throws -> FundEstimateCalibrationLedger {
        try JSONFilePersistence.load(
            FundEstimateCalibrationLedger.self,
            from: fileURL,
            defaultValue: FundEstimateCalibrationLedger()
        )
    }

    func save(_ ledger: FundEstimateCalibrationLedger, to fileURL: URL) throws {
        try JSONFilePersistence.save(ledger, to: fileURL)
    }
}
