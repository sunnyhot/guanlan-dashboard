import XCTest
@testable import QiemanDashboard

final class DisclosureInteractionPresentationTests: XCTestCase {
    func testSharedDisclosureStyleMakesTheWholeHeaderToggleExpansion() throws {
        let source = try source(at: "Views_macOS/SharedComponents.swift")
        let styleStart = try XCTUnwrap(source.range(of: "struct FullRowDisclosureGroupStyle: DisclosureGroupStyle"))
        let styleEnd = try XCTUnwrap(
            source.range(of: "private struct PressResponsiveButtonLabel", range: styleStart.upperBound..<source.endIndex)
        )
        let styleSource = String(source[styleStart.lowerBound..<styleEnd.lowerBound])

        XCTAssertTrue(styleSource.contains("Button"))
        XCTAssertTrue(styleSource.contains("configuration.isExpanded.toggle()"))
        XCTAssertTrue(styleSource.contains(".frame(maxWidth: .infinity"))
        XCTAssertTrue(styleSource.contains(".contentShape(Rectangle())"))
    }

    func testEveryAppDisclosureGroupUsesTheFullRowInteractionStyle() throws {
        try assertEveryDisclosureUsesFullRowStyle(in: "Views_macOS/SettingsMenuBarPanel.swift")
    }

    func testInlineDisclosureButtonOwnsTheSharedVisualAndInteractionStyle() throws {
        let source = try source(at: "Views_macOS/SharedComponents.swift")
        let styleStart = try XCTUnwrap(source.range(of: "struct InlineDisclosureButton: View"))
        let styleEnd = try XCTUnwrap(
            source.range(of: "private struct PressResponsiveButtonLabel", range: styleStart.upperBound..<source.endIndex)
        )
        let styleSource = String(source[styleStart.lowerBound..<styleEnd.lowerBound])

        XCTAssertTrue(styleSource.contains(".frame(maxWidth: .infinity)"))
        XCTAssertTrue(styleSource.contains(".onHover"))
        XCTAssertTrue(styleSource.contains(".accessibilityValue"))
        XCTAssertTrue(styleSource.contains("accessibilityReduceMotion"))
    }

    private func assertEveryDisclosureUsesFullRowStyle(
        in relativePath: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let source = try source(at: relativePath)
        let boundDisclosureCount = source.components(separatedBy: "DisclosureGroup(").count - 1
        let automaticDisclosureCount = source.components(separatedBy: "DisclosureGroup {").count - 1
        let disclosureCount = boundDisclosureCount + automaticDisclosureCount
        let fullRowStyleCount = source.components(separatedBy: ".disclosureGroupStyle(FullRowDisclosureGroupStyle())").count - 1

        XCTAssertEqual(fullRowStyleCount, disclosureCount, file: file, line: line)
    }

    private func source(at relativePath: String) throws -> String {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
