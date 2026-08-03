import Foundation
#if canImport(CoreImage)
import CoreImage
import CoreImage.CIFilterBuiltins
#endif
import SwiftUI

// MARK: - QR 码生成与解析

enum QRCodeHelper {
    /// 同步凭证编码成字符串(groupId + accessToken,不含密码)。
    /// 密码需手动在第二台设备输入(更安全)。
    static func encodeSyncCredentials(groupId: String, accessToken: String) -> String {
        "qieman-sync:\(groupId):\(accessToken)"
    }

    /// 解析同步凭证字符串。
    static func decodeSyncCredentials(_ raw: String) -> (groupId: String, accessToken: String)? {
        let parts = raw.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "qieman-sync" else { return nil }
        let gid = String(parts[1])
        let tok = String(parts[2])
        guard !gid.isEmpty, !tok.isEmpty else { return nil }
        return (gid, tok)
    }

    #if canImport(CoreImage)
    /// 生成二维码图片。
    static func generateQRImage(from string: String, scale: CGFloat = 8) -> NSUIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        #if os(macOS)
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
        #else
        return UIImage(cgImage: cgImage)
        #endif
    }
    #endif
}

// MARK: - 跨平台 NSUIImage

#if os(macOS)
import AppKit
typealias NSUIImage = NSImage
#elseif os(iOS)
import UIKit
typealias NSUIImage = UIImage
#endif
