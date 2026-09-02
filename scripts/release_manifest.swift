import Foundation

let environment = ProcessInfo.processInfo.environment
guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("用法：swift release_manifest.swift OUTPUT_PATH [--published-now]\n".utf8))
    exit(2)
}

func required(_ key: String) -> String {
    guard let value = environment[key], !value.isEmpty else {
        FileHandle.standardError.write(Data("缺少环境变量：\(key)\n".utf8))
        exit(2)
    }
    return value
}

let version = required("VERSION")
let tag = required("TAG")
let zipName = required("ZIP_NAME")
let zipSize = Int(required("ZIP_SIZE")) ?? 0
let sha256 = required("SHA256")
let downloadURL = required("DOWNLOAD_URL")
let releaseURL = required("RELEASE_URL")
let body = environment["BODY", default: ""]
let publishedAt = CommandLine.arguments.contains("--published-now")
    ? ISO8601DateFormatter().string(from: Date())
    : ""

let asset: [String: Any] = [
    "name": zipName,
    "download_url": downloadURL,
    "size": zipSize,
    "content_type": "application/zip",
    "sha256": sha256,
]
let payload: [String: Any] = [
    "version": version,
    "tag": tag,
    "asset": asset,
    "sha256": sha256,
    "notes": body,
    "html_url": releaseURL,
    "published_at": publishedAt,
    "tag_name": tag,
    "name": "观澜 \(tag)",
    "body": body,
    "assets": [[
        "name": zipName,
        "browser_download_url": downloadURL,
        "size": zipSize,
        "content_type": "application/zip",
    ]],
]
let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
var output = data
output.append(Data("\n".utf8))
try output.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
