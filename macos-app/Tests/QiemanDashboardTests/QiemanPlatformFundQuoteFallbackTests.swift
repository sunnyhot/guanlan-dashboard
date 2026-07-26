import Foundation
import XCTest
@testable import QiemanDashboard

final class QiemanPlatformFundQuoteFallbackTests: XCTestCase {
    private let now = QiemanPlatformFundQuoteFallbackTests.date("2026-07-20 16:52:41")

    override func tearDown() {
        MockQiemanPlatformURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testPortfolioUsesLatestOfficialNavWhenPrimaryQuoteIsEmpty() async throws {
        let expectedNAVs = [
            "002286": 1.2021,
            "100050": 1.2672,
            "006327": 0.8629,
        ]

        MockQiemanPlatformURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            switch url.host {
            case "fund.eastmoney.com":
                return Self.response(
                    for: url,
                    data: Data("""
                    var fS_name = "测试 QDII";
                    var Data_netWorthTrend = [];
                    """.utf8)
                )
            case "fundgz.1234567.com.cn":
                return Self.response(for: url, data: Data("jsonpgz();".utf8))
            case "hq.sinajs.cn", "qt.gtimg.cn":
                return Self.response(for: url, data: Data("var empty=\"\";".utf8))
            case "api.fund.eastmoney.com":
                let code = try XCTUnwrap(Self.queryValue("fundCode", in: url))
                let nav = try XCTUnwrap(expectedNAVs[code])
                let data = try JSONSerialization.data(withJSONObject: [
                    "ErrCode": 0,
                    "Data": [
                        "LSJZList": [[
                            "DWJZ": String(format: "%.4f", nav),
                            "FSRQ": "2026-07-13",
                            "JZZZL": "-0.21",
                        ]],
                    ],
                ])
                return Self.response(for: url, data: data)
            default:
                XCTFail("Unexpected request: \(url.absoluteString)")
                throw URLError(.unsupportedURL)
            }
        }

        let client = makeClient()
        let holdings = expectedNAVs.keys.map {
            UserPortfolioHolding(
                fundCode: $0,
                assetType: .fund,
                units: 100,
                costPrice: 1,
                displayName: "测试基金 \($0)",
                fundMarket: .offExchange
            )
        }

        let snapshot = try await client.fetchUserPortfolioSnapshot(holdings: holdings)
        let rowsByCode = Dictionary(uniqueKeysWithValues: snapshot.rows.map {
            ($0.holding.normalizedFundCode, $0)
        })

        for (code, nav) in expectedNAVs {
            let row = try XCTUnwrap(rowsByCode[code])
            XCTAssertEqual(row.currentPrice, nav)
            XCTAssertEqual(row.officialNav, nav)
            XCTAssertEqual(row.officialNavDate, "2026-07-13")
            XCTAssertEqual(try XCTUnwrap(row.marketValue), nav * 100, accuracy: 0.001)
            XCTAssertNil(row.estimatePrice)
            XCTAssertEqual(row.estimateChangePct, -0.21)
            XCTAssertNotNil(row.estimatedDailyChangeAmount)
        }
    }

    func testLatestOfficialNavPublishesCurrentDayChangeWhenDateMatchesToday() async throws {
        MockQiemanPlatformURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            switch url.host {
            case "fund.eastmoney.com":
                return Self.response(
                    for: url,
                    data: Data("""
                    var fS_name = "当日已披露基金";
                    var Data_netWorthTrend = [];
                    """.utf8)
                )
            case "fundgz.1234567.com.cn":
                XCTFail("当日官方净值可用时不应继续请求旧估值源")
                throw URLError(.unsupportedURL)
            case "api.fund.eastmoney.com":
                let data = try JSONSerialization.data(withJSONObject: [
                    "ErrCode": 0,
                    "Data": [
                        "LSJZList": [[
                            "DWJZ": "1.0250",
                            "FSRQ": "2026-07-20",
                            "JZZZL": "2.50",
                        ]],
                    ],
                ])
                return Self.response(for: url, data: data)
            default:
                XCTFail("Unexpected request: \(url.absoluteString)")
                throw URLError(.unsupportedURL)
            }
        }

        let snapshot = try await makeClient().fetchUserPortfolioSnapshot(
            holdings: [holding(code: "000001")]
        )
        let row = try XCTUnwrap(snapshot.rows.first)

        XCTAssertEqual(row.currentPrice, 1.025)
        XCTAssertEqual(row.officialNavDate, "2026-07-20")
        XCTAssertEqual(row.estimateChangePct, 2.5)
        XCTAssertEqual(try XCTUnwrap(row.estimatedDailyChangeAmount), 2.5, accuracy: 0.01)
        XCTAssertEqual(snapshot.dailyChangeCoverageCount, 1)
        XCTAssertEqual(snapshot.refreshNoticeMessage, "个人持仓估值和涨跌已刷新。")
    }

    func testInvalidLatestNavResponseFallsBackToHistory() async throws {
        MockQiemanPlatformURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            switch url.host {
            case "fund.eastmoney.com":
                return Self.response(
                    for: url,
                    data: Data("""
                    var fS_name = "历史兜底基金";
                    var Data_netWorthTrend = [{"x":1783872000000,"y":1.1111}];
                    """.utf8)
                )
            case "fundgz.1234567.com.cn":
                return Self.response(for: url, data: Data("jsonpgz();".utf8))
            case "hq.sinajs.cn", "qt.gtimg.cn":
                return Self.response(for: url, data: Data("var empty=\"\";".utf8))
            case "api.fund.eastmoney.com":
                let data = try JSONSerialization.data(withJSONObject: [
                    "ErrCode": 1,
                    "Data": ["LSJZList": []],
                ])
                return Self.response(for: url, data: data)
            default:
                XCTFail("Unexpected request: \(url.absoluteString)")
                throw URLError(.unsupportedURL)
            }
        }

        let snapshot = try await makeClient().fetchUserPortfolioSnapshot(
            holdings: [holding(code: "002286")]
        )
        let row = try XCTUnwrap(snapshot.rows.first)

        XCTAssertEqual(row.currentPrice, 1.1111)
        XCTAssertEqual(row.officialNav, 1.1111)
        XCTAssertEqual(row.priceSource, "最近净值")
        XCTAssertNil(row.estimateChangePct)
    }

    func testHistoryFallbackPublishesCurrentDayEquityReturn() async throws {
        MockQiemanPlatformURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            switch url.host {
            case "fund.eastmoney.com":
                return Self.response(
                    for: url,
                    data: Data("""
                    var fS_name = "历史当日兜底基金";
                    var Data_netWorthTrend = [{"x":1784476800000,"y":1.0200,"equityReturn":2.00}];
                    """.utf8)
                )
            case "fundgz.1234567.com.cn":
                return Self.response(for: url, data: Data("jsonpgz();".utf8))
            case "api.fund.eastmoney.com":
                let data = try JSONSerialization.data(withJSONObject: [
                    "ErrCode": 1,
                    "Data": ["LSJZList": []],
                ])
                return Self.response(for: url, data: data)
            default:
                XCTFail("Unexpected request: \(url.absoluteString)")
                throw URLError(.unsupportedURL)
            }
        }

        let snapshot = try await makeClient().fetchUserPortfolioSnapshot(
            holdings: [holding(code: "000001")]
        )
        let row = try XCTUnwrap(snapshot.rows.first)

        XCTAssertEqual(row.officialNavDate, "2026-07-20")
        XCTAssertEqual(row.estimateChangePct, 2)
        XCTAssertEqual(try XCTUnwrap(row.estimatedDailyChangeAmount), 2, accuracy: 0.01)
    }

    func testLegacyCurrentEstimateIsUsedWhenOfficialNavIsNotFromToday() async throws {
        MockQiemanPlatformURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            switch url.host {
            case "fund.eastmoney.com":
                return Self.response(
                    for: url,
                    data: Data("""
                    var fS_name = "正常估值基金";
                    var Data_netWorthTrend = [];
                    """.utf8)
                )
            case "fundgz.1234567.com.cn":
                return Self.response(
                    for: url,
                    data: Data("""
                    jsonpgz({"fundcode":"000369","name":"正常估值基金","jzrq":"2026-07-17","dwjz":"2.5060","gsz":"2.5074","gszzl":"0.06","gztime":"2026-07-20 14:00"});
                    """.utf8)
                )
            case "api.fund.eastmoney.com":
                let data = try JSONSerialization.data(withJSONObject: [
                    "ErrCode": 0,
                    "Data": [
                        "LSJZList": [[
                            "DWJZ": "2.5060",
                            "FSRQ": "2026-07-17",
                            "JZZZL": "-0.21",
                        ]],
                    ],
                ])
                return Self.response(for: url, data: data)
            default:
                XCTFail("Unexpected request: \(url.absoluteString)")
                throw URLError(.unsupportedURL)
            }
        }

        let snapshot = try await makeClient().fetchUserPortfolioSnapshot(
            holdings: [holding(code: "000369")]
        )
        let row = try XCTUnwrap(snapshot.rows.first)

        XCTAssertEqual(row.currentPrice, 2.5060)
        XCTAssertEqual(row.estimatePrice, 2.5074)
        XCTAssertEqual(row.estimateChangePct, 0.06)
    }

    func testSinaCurrentEstimateBackfillsRetiredLegacySource() async throws {
        MockQiemanPlatformURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            switch url.host {
            case "fund.eastmoney.com":
                return Self.response(
                    for: url,
                    data: Data("""
                    var fS_name = "兴全商业模式混合(LOF)A";
                    var Data_netWorthTrend = [];
                    """.utf8)
                )
            case "api.fund.eastmoney.com":
                let data = try JSONSerialization.data(withJSONObject: [
                    "ErrCode": 0,
                    "Data": [
                        "LSJZList": [[
                            "DWJZ": "5.1120",
                            "FSRQ": "2026-07-17",
                            "JZZZL": "-5.99",
                        ]],
                    ],
                ])
                return Self.response(for: url, data: data)
            case "fundgz.1234567.com.cn":
                return Self.response(for: url, data: Data("jsonpgz();".utf8))
            case "hq.sinajs.cn":
                return Self.response(
                    for: url,
                    data: Data("""
                    var hq_str_fu_163415="兴全商业模式混合(LOF)A,16:04:00,5.0374,5.1120,5.9720,0,-1.4593,2026-07-20,5.0679,-0.8627";
                    """.utf8)
                )
            default:
                XCTFail("Unexpected request: \(url.absoluteString)")
                throw URLError(.unsupportedURL)
            }
        }

        let snapshot = try await makeClient().fetchUserPortfolioSnapshot(
            holdings: [holding(code: "163415")]
        )
        let row = try XCTUnwrap(snapshot.rows.first)

        XCTAssertEqual(row.currentPrice, 5.112)
        XCTAssertEqual(row.estimatePrice, 5.0374)
        XCTAssertEqual(row.estimatePriceTime, "2026-07-20 16:04:00")
        XCTAssertEqual(row.estimateChangePct, -1.4593)
        XCTAssertEqual(row.priceSource, "最近净值 · 新浪盘中估值")
        XCTAssertEqual(snapshot.dailyChangeCoverageCount, 1)
    }

    func testMarketProxyEstimateCoversFundWithoutProviderEstimate() async throws {
        MockQiemanPlatformURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            switch url.host {
            case "fund.eastmoney.com":
                return Self.response(
                    for: url,
                    data: Data("""
                    var fS_name = "华泰柏瑞纳斯达克100ETF联接(QDII)A";
                    var Data_netWorthTrend = [];
                    """.utf8)
                )
            case "api.fund.eastmoney.com":
                let data = try JSONSerialization.data(withJSONObject: [
                    "ErrCode": 0,
                    "Data": [
                        "LSJZList": [[
                            "DWJZ": "1.6280",
                            "FSRQ": "2026-07-16",
                            "JZZZL": "-1.52",
                        ]],
                    ],
                ])
                return Self.response(for: url, data: data)
            case "fundgz.1234567.com.cn":
                return Self.response(for: url, data: Data("jsonpgz();".utf8))
            case "hq.sinajs.cn":
                return Self.response(for: url, data: Data("var hq_str_fu_019524=\"\";".utf8))
            case "qt.gtimg.cn":
                XCTAssertTrue(url.absoluteString.contains("usNDX"))
                return Self.response(
                    for: url,
                    data: Self.tencentQuoteData(
                        symbol: ".NDX",
                        name: "纳斯达克100",
                        price: "28592.66",
                        previousClose: "29025.77",
                        dateTime: "2026-07-17 17:15:59",
                        changePct: "-1.49"
                    )
                )
            default:
                XCTFail("Unexpected request: \(url.absoluteString)")
                throw URLError(.unsupportedURL)
            }
        }

        let snapshot = try await makeClient().fetchUserPortfolioSnapshot(
            holdings: [holding(code: "019524")]
        )
        let row = try XCTUnwrap(snapshot.rows.first)

        XCTAssertEqual(row.currentPrice, 1.628)
        XCTAssertEqual(try XCTUnwrap(row.estimatePrice), 1.6037, accuracy: 0.0001)
        XCTAssertEqual(row.estimateChangePct, -1.49)
        XCTAssertEqual(row.estimatePriceTime, "2026-07-17 17:15:59")
        XCTAssertEqual(row.priceSource, "最近净值 · 纳斯达克100代理估算")
        XCTAssertEqual(snapshot.dailyChangeCoverageCount, 1)
    }

    func testCurrentIndexFutureCoversQDIIWhenLastCloseAlreadyMatchesOfficialDate() async throws {
        MockQiemanPlatformURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            switch url.host {
            case "fund.eastmoney.com":
                return Self.response(
                    for: url,
                    data: Data("""
                    var fS_name = "华泰柏瑞纳斯达克100ETF联接(QDII)A";
                    var Data_netWorthTrend = [];
                    """.utf8)
                )
            case "api.fund.eastmoney.com":
                let data = try JSONSerialization.data(withJSONObject: [
                    "ErrCode": 0,
                    "Data": [
                        "LSJZList": [[
                            "DWJZ": "1.6280",
                            "FSRQ": "2026-07-17",
                            "JZZZL": "-1.52",
                        ]],
                    ],
                ])
                return Self.response(for: url, data: data)
            case "fundgz.1234567.com.cn":
                return Self.response(for: url, data: Data("jsonpgz();".utf8))
            case "qt.gtimg.cn":
                return Self.response(
                    for: url,
                    data: Self.tencentQuoteData(
                        symbol: ".NDX",
                        name: "纳斯达克100",
                        price: "28750.00",
                        previousClose: "29000.00",
                        dateTime: "2026-07-17 17:15:59",
                        changePct: "-0.86"
                    )
                )
            case "hq.sinajs.cn":
                if url.absoluteString.contains("fu_019524") {
                    return Self.response(for: url, data: Data("var hq_str_fu_019524=\"\";".utf8))
                }
                XCTAssertTrue(url.absoluteString.contains("hf_NQ"))
                return Self.response(
                    for: url,
                    data: Data("""
                    var hq_str_hf_NQ="29000.000,,28990.000,28995.000,29010.000,28700.000,18:20:00,28750.000,28740.000,0,1,1,2026-07-20,纳斯达克指数期货,0";
                    """.utf8)
                )
            default:
                XCTFail("Unexpected request: \(url.absoluteString)")
                throw URLError(.unsupportedURL)
            }
        }

        let snapshot = try await makeClient().fetchUserPortfolioSnapshot(
            holdings: [holding(code: "019524")]
        )
        let row = try XCTUnwrap(snapshot.rows.first)

        let expectedChangePct = (29_000.0 / 28_750.0 - 1) * 100
        XCTAssertEqual(try XCTUnwrap(row.estimateChangePct), expectedChangePct, accuracy: 0.000_001)
        XCTAssertEqual(row.estimatePriceTime, "2026-07-20 18:20:00")
        XCTAssertEqual(row.priceSource, "最近净值 · 纳指100期货代理估算")
        XCTAssertEqual(snapshot.dailyChangeCoverageCount, 1)
    }

    func testCurrentUSDCNYCoversDollarBondWhenBondCloseAlreadyMatchesOfficialDate() async throws {
        MockQiemanPlatformURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            switch url.host {
            case "fund.eastmoney.com":
                return Self.response(
                    for: url,
                    data: Data("""
                    var fS_name = "中银美元债债券(QDII)A";
                    var Data_netWorthTrend = [];
                    """.utf8)
                )
            case "api.fund.eastmoney.com":
                let data = try JSONSerialization.data(withJSONObject: [
                    "ErrCode": 0,
                    "Data": [
                        "LSJZList": [[
                            "DWJZ": "1.2042",
                            "FSRQ": "2026-07-17",
                            "JZZZL": "-0.08",
                        ]],
                    ],
                ])
                return Self.response(for: url, data: data)
            case "fundgz.1234567.com.cn":
                return Self.response(for: url, data: Data("jsonpgz();".utf8))
            case "qt.gtimg.cn":
                return Self.response(
                    for: url,
                    data: Self.tencentQuoteData(
                        symbol: "AGG",
                        name: "美国综合债券ETF",
                        price: "99.80",
                        previousClose: "100.00",
                        dateTime: "2026-07-17 16:00:00",
                        changePct: "-0.20"
                    )
                )
            case "hq.sinajs.cn":
                if url.absoluteString.contains("fu_002286") {
                    return Self.response(for: url, data: Data("var hq_str_fu_002286=\"\";".utf8))
                }
                XCTAssertTrue(url.absoluteString.contains("fx_susdcny"))
                return Self.response(
                    for: url,
                    data: Data("""
                    var hq_str_fx_susdcny="18:25:26,6.7682,6.7698,6.7752,234,6.7677,6.7768,6.7534,6.7690,美元人民币,-0.0915,-0.0062,0.0234,行情,0,0,,2026-07-20";
                    """.utf8)
                )
            default:
                XCTFail("Unexpected request: \(url.absoluteString)")
                throw URLError(.unsupportedURL)
            }
        }

        let snapshot = try await makeClient().fetchUserPortfolioSnapshot(
            holdings: [holding(code: "002286")]
        )
        let row = try XCTUnwrap(snapshot.rows.first)

        let expectedChangePct = (6.7690 / 6.7752 - 1) * 100
        XCTAssertEqual(try XCTUnwrap(row.estimateChangePct), expectedChangePct, accuracy: 0.000_001)
        XCTAssertEqual(row.estimatePriceTime, "2026-07-20 18:25:26")
        XCTAssertEqual(row.priceSource, "最近净值 · 美元兑人民币代理估算")
        XCTAssertEqual(snapshot.dailyChangeCoverageCount, 1)
    }

    func testStalePrimaryEstimateFallsBackToLatestOfficialChange() async throws {
        MockQiemanPlatformURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            switch url.host {
            case "fund.eastmoney.com":
                return Self.response(
                    for: url,
                    data: Data("""
                    var fS_name = "估值已过期基金";
                    var Data_netWorthTrend = [];
                    """.utf8)
                )
            case "fundgz.1234567.com.cn":
                return Self.response(
                    for: url,
                    data: Data("""
                    jsonpgz({"fundcode":"000001","name":"估值已过期基金","jzrq":"2026-07-17","dwjz":"1.0000","gsz":"1.0900","gszzl":"9.00","gztime":"2026-07-17 14:00"});
                    """.utf8)
                )
            case "api.fund.eastmoney.com":
                let data = try JSONSerialization.data(withJSONObject: [
                    "ErrCode": 0,
                    "Data": [
                        "LSJZList": [[
                            "DWJZ": "1.0000",
                            "FSRQ": "2026-07-17",
                            "JZZZL": "9.00",
                        ]],
                    ],
                ])
                return Self.response(for: url, data: data)
            case "hq.sinajs.cn", "qt.gtimg.cn":
                return Self.response(for: url, data: Data("var empty=\"\";".utf8))
            default:
                XCTFail("Unexpected request: \(url.absoluteString)")
                throw URLError(.unsupportedURL)
            }
        }

        let snapshot = try await makeClient().fetchUserPortfolioSnapshot(
            holdings: [holding(code: "000001")]
        )
        let row = try XCTUnwrap(snapshot.rows.first)

        XCTAssertNil(row.estimatePrice)
        XCTAssertEqual(row.estimateChangePct, 9)
        XCTAssertEqual(
            try XCTUnwrap(row.estimatedDailyChangeAmount),
            100 - 100 / 1.09,
            accuracy: 0.001
        )
        XCTAssertEqual(snapshot.dailyChangeCoverageCount, 1)
    }

    func testLatestOfficialNavDerivesChangeFromPreviousPublishedNAV() async throws {
        MockQiemanPlatformURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            switch url.host {
            case "fund.eastmoney.com":
                return Self.response(
                    for: url,
                    data: Data("""
                    var fS_name = "净值计算基金";
                    var Data_netWorthTrend = [];
                    """.utf8)
                )
            case "api.fund.eastmoney.com":
                let data = try JSONSerialization.data(withJSONObject: [
                    "ErrCode": 0,
                    "Data": [
                        "LSJZList": [
                            ["DWJZ": "1.0300", "FSRQ": "2026-07-17", "JZZZL": NSNull()],
                            ["DWJZ": "1.0000", "FSRQ": "2026-07-16", "JZZZL": "0.00"],
                        ],
                    ],
                ])
                return Self.response(for: url, data: data)
            case "fundgz.1234567.com.cn":
                return Self.response(for: url, data: Data("jsonpgz();".utf8))
            case "hq.sinajs.cn", "qt.gtimg.cn":
                return Self.response(for: url, data: Data("var empty=\"\";".utf8))
            default:
                XCTFail("Unexpected request: \(url.absoluteString)")
                throw URLError(.unsupportedURL)
            }
        }

        let snapshot = try await makeClient().fetchUserPortfolioSnapshot(
            holdings: [holding(code: "000001")]
        )
        let row = try XCTUnwrap(snapshot.rows.first)

        XCTAssertEqual(row.currentPrice, 1.03)
        XCTAssertEqual(try XCTUnwrap(row.estimateChangePct), 3, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(row.estimatedDailyChangeAmount), 3, accuracy: 0.001)
        XCTAssertEqual(row.changePeriodTitle(marketDate: "2026-07-20"), "最近涨跌")
    }

    func testStockUsesLastMarketQuoteAndItsActualTradingDate() async throws {
        MockQiemanPlatformURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            guard url.host == "push2.eastmoney.com" else {
                XCTFail("Unexpected request: \(url.absoluteString)")
                throw URLError(.unsupportedURL)
            }
            let data = try JSONSerialization.data(withJSONObject: [
                "data": [
                    "f43": 129_741,
                    "f57": "600519",
                    "f58": "贵州茅台",
                    "f59": 2,
                    "f60": 129_201,
                    "f86": 1_784_271_600,
                    "f170": 42,
                ],
            ])
            return Self.response(for: url, data: data)
        }

        let snapshot = try await makeClient().fetchUserPortfolioSnapshot(
            holdings: [stockHolding(code: "600519")]
        )
        let row = try XCTUnwrap(snapshot.rows.first)

        XCTAssertEqual(row.currentPrice, 1_297.41)
        XCTAssertEqual(row.priceTime.map { String($0.prefix(10)) }, "2026-07-17")
        XCTAssertEqual(row.estimateChangePct, 0.42)
        XCTAssertNotNil(row.estimatedDailyChangeAmount)
        XCTAssertEqual(row.changePeriodTitle(marketDate: "2026-07-20"), "最近涨跌")
        XCTAssertEqual(row.dropdownQuote(marketDate: "2026-07-20").label, "最新净值")
    }

    func testForcedQuoteRefreshBypassesUsableQuoteCache() async throws {
        let counter = LockedRequestCounter()
        MockQiemanPlatformURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            switch url.host {
            case "fund.eastmoney.com":
                return Self.response(
                    for: url,
                    data: Data("""
                    var fS_name = "手动刷新基金";
                    var Data_netWorthTrend = [];
                    """.utf8)
                )
            case "fundgz.1234567.com.cn":
                return Self.response(for: url, data: Data("jsonpgz();".utf8))
            case "api.fund.eastmoney.com":
                counter.increment("latest-nav")
                let nav = counter.value(for: "latest-nav") == 1 ? "1.0000" : "1.1000"
                let data = try JSONSerialization.data(withJSONObject: [
                    "ErrCode": 0,
                    "Data": [
                        "LSJZList": [[
                            "DWJZ": nav,
                            "FSRQ": "2026-07-20",
                            "JZZZL": "0.00",
                        ]],
                    ],
                ])
                return Self.response(for: url, data: data)
            case "hq.sinajs.cn", "qt.gtimg.cn":
                return Self.response(for: url, data: Data("var empty=\"\";".utf8))
            default:
                XCTFail("Unexpected request: \(url.absoluteString)")
                throw URLError(.unsupportedURL)
            }
        }

        let client = makeClient()
        let holdings = [holding(code: "000001")]
        let first = try await client.fetchUserPortfolioSnapshot(holdings: holdings)
        let cached = try await client.fetchUserPortfolioSnapshot(holdings: holdings)
        let forced = try await client.fetchUserPortfolioSnapshot(
            holdings: holdings,
            forceQuoteRefresh: true
        )

        XCTAssertEqual(first.rows.first?.currentPrice, 1)
        XCTAssertEqual(cached.rows.first?.currentPrice, 1)
        XCTAssertEqual(forced.rows.first?.currentPrice, 1.1)
        XCTAssertEqual(counter.value(for: "latest-nav"), 2)
    }

    func testUnavailableFundDataIsRetriedInsteadOfCached() async throws {
        let counter = LockedRequestCounter()
        MockQiemanPlatformURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            let key = url.host ?? "unknown"
            counter.increment(key)

            switch url.host {
            case "fund.eastmoney.com":
                return Self.response(
                    for: url,
                    data: Data("""
                    var fS_name = "暂无数据基金";
                    var Data_netWorthTrend = [];
                    """.utf8)
                )
            case "fundgz.1234567.com.cn":
                return Self.response(for: url, data: Data("jsonpgz();".utf8))
            case "api.fund.eastmoney.com":
                let data = try JSONSerialization.data(withJSONObject: [
                    "ErrCode": 0,
                    "Data": ["LSJZList": []],
                ])
                return Self.response(for: url, data: data)
            case "hq.sinajs.cn", "qt.gtimg.cn":
                return Self.response(for: url, data: Data("var empty=\"\";".utf8))
            default:
                XCTFail("Unexpected request: \(url.absoluteString)")
                throw URLError(.unsupportedURL)
            }
        }

        let client = makeClient()
        let holdings = [holding(code: "002286")]
        let first = try await client.fetchUserPortfolioSnapshot(holdings: holdings)
        let second = try await client.fetchUserPortfolioSnapshot(holdings: holdings)

        XCTAssertNil(first.rows.first?.marketValue)
        XCTAssertNil(second.rows.first?.marketValue)
        XCTAssertEqual(counter.value(for: "fund.eastmoney.com"), 2)
        XCTAssertEqual(counter.value(for: "fundgz.1234567.com.cn"), 2)
        XCTAssertEqual(counter.value(for: "api.fund.eastmoney.com"), 2)
        XCTAssertEqual(counter.value(for: "hq.sinajs.cn"), 2)
        XCTAssertEqual(counter.value(for: "qt.gtimg.cn"), 0)
    }

    private func makeClient() -> QiemanPlatformNativeClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockQiemanPlatformURLProtocol.self]
        return QiemanPlatformNativeClient(
            session: URLSession(configuration: configuration),
            now: { self.now }
        )
    }

    private func holding(code: String) -> UserPortfolioHolding {
        UserPortfolioHolding(
            fundCode: code,
            assetType: .fund,
            units: 100,
            costPrice: 1,
            displayName: "测试基金 \(code)",
            fundMarket: .offExchange
        )
    }

    private func stockHolding(code: String) -> UserPortfolioHolding {
        UserPortfolioHolding(
            fundCode: code,
            assetType: .stock,
            units: 100,
            costPrice: 1_000,
            displayName: "测试股票 \(code)",
            stockMarket: .aShare
        )
    }

    private static func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }

    private static func response(for url: URL, data: Data) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, data)
    }

    private static func tencentQuoteData(
        symbol: String,
        name: String,
        price: String,
        previousClose: String,
        dateTime: String,
        changePct: String
    ) -> Data {
        var parts = Array(repeating: "", count: 33)
        parts[1] = name
        parts[2] = symbol
        parts[3] = price
        parts[4] = previousClose
        parts[30] = dateTime
        parts[32] = changePct
        return Data("v_proxy=\"\(parts.joined(separator: "~"))\";".utf8)
    }

    private static func date(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: value)!
    }
}

private final class MockQiemanPlatformURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class LockedRequestCounter {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func increment(_ key: String) {
        lock.lock()
        counts[key, default: 0] += 1
        lock.unlock()
    }

    func value(for key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[key, default: 0]
    }
}
