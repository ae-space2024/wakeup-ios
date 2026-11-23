import Foundation
import Security

// ============================================================================
// MARK: - 通用工具
// ============================================================================

extension Data {
    /// JWT 用的 base64url 解码（先把 -/_ 换回 +/，再补 =）
    init?(base64URLEncoded s: String) {
        var x = s.replacingOccurrences(of: "-", with: "+")
                 .replacingOccurrences(of: "_", with: "/")
        let r = x.count % 4
        if r > 0 { x += String(repeating: "=", count: 4 - r) }
        self.init(base64Encoded: x)
    }
}

/// 安全地把 Data 解析成 JSON 字典（失败返回空字典）
func asDict(_ data: Data) -> [String: Any] {
    guard let obj = try? JSONSerialization.jsonObject(with: data),
          let dict = obj as? [String: Any] else { return [:] }
    return dict
}

/// 从 JWT 里读 exp（秒）。解析失败返回 0。
func jwtExp(_ token: String) -> Int64 {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count >= 2,
          let d = Data(base64URLEncoded: String(parts[1])),
          let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return 0 }
    if let n = obj["exp"] as? NSNumber { return n.int64Value }
    if let n = obj["exp"] as? Int { return Int64(n) }
    return 0
}

// ============================================================================
// MARK: - Keychain 存取（替代 Windows DPAPI）
// ============================================================================

enum KeychainStore {
    private static let service = "com.wakeup.power.credentials"

    static func set(_ value: String, forKey key: String) {
        guard let data = value.data(using: .utf8) else { return }
        let base: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key
        ]
        SecItemDelete(base as CFDictionary)
        let add: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key
        ]
        SecItemDelete(q as CFDictionary)
    }
}

// ============================================================================
// MARK: - 错误类型
// ============================================================================

enum AppError: LocalizedError {
    case input(String)
    case network(String)
    case api(String)

    var errorDescription: String? {
        switch self {
        case .input(let s), .network(let s), .api(let s): return s
        }
    }
}
