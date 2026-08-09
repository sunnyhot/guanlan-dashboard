import Foundation
import CommonCrypto
import CryptoKit

// MARK: - ArchiveCipher
//
// 端到端加密密文容器。协议见 PROTOCOL.md 第 4 节。
//
// 密文格式(AAD 认证头部):
//   magic("QMDB") + cipherVersion(1B) + kdfIDLen(1B) + kdfID
//   + iterCount(4B BE) + saltLen(1B) + salt(32B)
//   + nonceLen(1B) + nonce(12B) + ciphertext+tag
//
// 头部(到 nonce 结束)作为 AES-GCM 的 AAD 一起认证。
// 密码错误或密文损坏统一抛 authenticationFailed(GCM 无法区分两者)。

enum ArchiveCipher {
    static let magic: [UInt8] = [0x51, 0x4D, 0x44, 0x42]  // "QMDB"
    static let cipherVersion: UInt8 = 1
    static let kdfID = "PBKDF2-SHA256"
    static let saltLength = 32
    static let nonceLength = 12
    static let defaultIterations: UInt32 = 600_000
    static let derivedKeyLength = 32  // AES-256

    // MARK: - 加密

    /// 加密明文 Data,返回密文(含头部)。
    /// - Parameters:
    ///   - plaintext: 待加密数据
    ///   - password: 用户密码
    ///   - iterations: PBKDF2 迭代次数(默认 600000)
    static func encrypt(_ plaintext: Data, password: String,
                        iterations: UInt32 = defaultIterations) throws -> Data {
        // 1. 生成随机 salt + nonce
        var salt = [UInt8](repeating: 0, count: saltLength)
        let randomStatus = SecRandomCopyBytes(kSecRandomDefault, saltLength, &salt)
        guard randomStatus == errSecSuccess else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(randomStatus),
                userInfo: [NSLocalizedDescriptionKey: "无法生成加密随机盐值。"]
            )
        }

        let nonce = AES.GCM.Nonce()

        // 2. PBKDF2 派生密钥
        let key = try deriveKey(password: password, salt: salt, iterations: iterations)

        // 3. 组装 AAD 头部(magic + cipherVersion + kdfID + iterCount + salt + nonce)
        let header = buildHeader(salt: salt, nonceData: Data(nonce), iterations: iterations)

        // 4. AES-GCM 加密(头部作为 AAD)
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: header)

        // 5. 输出: header + ciphertext + tag
        var output = header
        output.append(sealed.ciphertext)
        output.append(sealed.tag)
        return output
    }

    // MARK: - 解密

    /// 解密密文,返回明文 Data。
    /// 密码错误或密文损坏抛 SyncError.authenticationFailed。
    static func decrypt(_ ciphertext: Data, password: String) throws -> Data {
        // 1. 解析头部
        let parsed = try parseHeader(ciphertext)

        // 2. PBKDF2 派生密钥
        let key = try deriveKey(password: password, salt: parsed.salt, iterations: parsed.iterations)

        // 3. 提取 ciphertext + tag
        let sealedCiphertext = ciphertext.subdata(in: parsed.bodyRange)
        // GCM tag 是最后 16 字节
        let tagStart = sealedCiphertext.count - 16
        let ct = sealedCiphertext.subdata(in: 0..<tagStart)
        let tag = sealedCiphertext.subdata(in: tagStart..<sealedCiphertext.count)

        // 4. AES-GCM 解密(头部作为 AAD 验证)
        let header = ciphertext.subdata(in: 0..<parsed.headerLength)
        let sealed = try AES.GCM.SealedBox(nonce: parsed.nonce,
                                           ciphertext: ct, tag: tag)
        do {
            return try AES.GCM.open(sealed, using: key, authenticating: header)
        } catch {
            throw SyncError.authenticationFailed
        }
    }

    // MARK: - 头部构建/解析

    private static func buildHeader(salt: [UInt8], nonceData: Data, iterations: UInt32) -> Data {
        var data = Data()
        data.append(contentsOf: magic)
        data.append(cipherVersion)
        let kdfBytes = Array(kdfID.utf8)
        data.append(UInt8(kdfBytes.count))
        data.append(contentsOf: kdfBytes)
        // iterCount 大端 4 字节
        data.append(UInt8((iterations >> 24) & 0xFF))
        data.append(UInt8((iterations >> 16) & 0xFF))
        data.append(UInt8((iterations >> 8) & 0xFF))
        data.append(UInt8(iterations & 0xFF))
        data.append(UInt8(salt.count))
        data.append(contentsOf: salt)
        data.append(UInt8(nonceData.count))
        data.append(nonceData)
        return data
    }

    private struct ParsedHeader {
        let salt: [UInt8]
        let nonce: AES.GCM.Nonce
        let iterations: UInt32
        let headerLength: Int
        let bodyRange: Range<Int>
    }

    private static func parseHeader(_ data: Data) throws -> ParsedHeader {
        var offset = 0

        // magic(4)
        guard data.count >= offset + 4,
              Array(data[offset..<offset+4]) == magic else {
            throw SyncError.authenticationFailed
        }
        offset += 4

        // cipherVersion(1)
        guard data.count > offset, data[offset] == cipherVersion else {
            throw SyncError.authenticationFailed
        }
        offset += 1

        // kdfIDLen(1) + kdfID
        guard data.count > offset else { throw SyncError.authenticationFailed }
        let kdfLen = Int(data[offset]); offset += 1
        guard data.count >= offset + kdfLen else { throw SyncError.authenticationFailed }
        let kdf = String(data: data.subdata(in: offset..<offset+kdfLen), encoding: .utf8)
        guard kdf == kdfID else { throw SyncError.authenticationFailed }
        offset += kdfLen

        // iterCount(4 BE)
        guard data.count >= offset + 4 else { throw SyncError.authenticationFailed }
        let iterations: UInt32 = (UInt32(data[offset]) << 24) |
                                 (UInt32(data[offset+1]) << 16) |
                                 (UInt32(data[offset+2]) << 8) |
                                 UInt32(data[offset+3])
        offset += 4

        // saltLen(1) + salt
        guard data.count > offset else { throw SyncError.authenticationFailed }
        let sLen = Int(data[offset]); offset += 1
        guard sLen == saltLength, data.count >= offset + sLen else { throw SyncError.authenticationFailed }
        let salt = Array(data[offset..<offset+sLen])
        offset += sLen

        // nonceLen(1) + nonce
        guard data.count > offset else { throw SyncError.authenticationFailed }
        let nLen = Int(data[offset]); offset += 1
        guard nLen == nonceLength, data.count >= offset + nLen else { throw SyncError.authenticationFailed }
        let nonceData = data.subdata(in: offset..<offset+nLen)
        offset += nLen

        // nonce 对象
        let nonce: AES.GCM.Nonce
        do {
            nonce = try AES.GCM.Nonce(data: nonceData)
        } catch {
            throw SyncError.authenticationFailed
        }

        let headerLength = offset
        let bodyRange = headerLength..<data.count

        return ParsedHeader(salt: salt, nonce: nonce, iterations: iterations,
                            headerLength: headerLength, bodyRange: bodyRange)
    }

    // MARK: - PBKDF2 密钥派生

    private static func deriveKey(password: String, salt: [UInt8], iterations: UInt32) throws -> SymmetricKey {
        let passwordBytes = Array(password.utf8)
        var derived = [UInt8](repeating: 0, count: derivedKeyLength)

        // CCKeyDerivationPBKDF 的 password 参数是 UnsafePointer<CChar>(null-terminated)。
        // password.utf8 + \0 满足要求。
        var pwCStr = passwordBytes.map { CChar(bitPattern: $0) }
        pwCStr.append(0)  // null terminator

        let status = pwCStr.withUnsafeBufferPointer { pwPtr in
            salt.withUnsafeBufferPointer { saltPtr in
                derived.withUnsafeMutableBufferPointer { derivedPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwPtr.baseAddress, passwordBytes.count,
                        saltPtr.baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        derivedPtr.baseAddress, derivedKeyLength
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            throw SyncError.authenticationFailed
        }

        return SymmetricKey(data: Data(derived))
    }
}
