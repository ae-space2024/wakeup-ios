import Foundation
import Security

// ============================================================================
// MARK: - 蒲公英：数据模型
// ============================================================================

struct PgyAccount: Codable, Identifiable {
    var sn: String = ""
    var accessToken: String = ""
    var refreshToken: String = ""
    var refreshExpires: Int64 = 0
    var rememberPassword: Bool = false
    var password: String = ""          // 仅本地，存 Keychain，不上传
    var id: String { sn }
}

struct PgyDevice: Decodable, Identifiable {
    let mac: String
    let hostname: String?
    let connType: String?
    let ip: String?
    let isonline: Bool

    var id: String { mac }

    enum CodingKeys: String, CodingKey {
        case mac, hostname, ip, isonline
        case connType = "conn_type"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mac       = try c.decodeIfPresent(String.self, forKey: .mac) ?? ""
        hostname  = try c.decodeIfPresent(String.self, forKey: .hostname)
        connType  = try c.decodeIfPresent(String.self, forKey: .connType)
        ip        = try c.decodeIfPresent(String.self, forKey: .ip)
        if let b = try? c.decodeIfPresent(Bool.self, forKey: .isonline) {
            isonline = b ?? false
        } else if let n = try? c.decodeIfPresent(Int.self, forKey: .isonline) {
            isonline = (n ?? 0) != 0
        } else {
            isonline = false
        }
    }
}

// ============================================================================
// MARK: - 蒲公英：网络服务
// ============================================================================

final class PgyService {
    static let shared = PgyService()

    private let loginBase = "https://pgyboxapi.sdwan.oray.com"
    private let apiBase   = "https://pgy-api.oray.com"
    private let authBase  = "https://auth.pgyapi.com"
    private let appId     = "WgswNd0Wly4kMYanPnHL"

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 20
        return URLSession(configuration: cfg)
    }()

    private let errorText: [String: String] = [
        "401001": "SN 码或设备密码错误",
        "400001": "密码错误",
        "400015": "请求参数错误",
        "400016": "缺少必填参数",
        "400018": "密码错误次数过多，账号已临时锁定"
    ]

    // ------------------------------------------------------------------
    // RSA PKCS#1 v1.5 加密（对应 Python cryptography 的 padding.PKCS1v15）
    // ------------------------------------------------------------------
    private func rsaEncrypt(pem: String, plain: String) throws -> String {
        // 去掉 PEM 头尾与空白，得到 DER base64
        let body = pem
            .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----BEGIN RSA PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END RSA PUBLIC KEY-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()

        guard let der = Data(base64Encoded: body) else {
            throw AppError.api("公钥格式错误")
        }

        let attrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic
        ]
        var err: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, &err) else {
            let msg = err?.takeRetainedValue().localizedDescription ?? "未知错误"
            throw AppError.api("公钥解析失败: \(msg)")
        }

        guard let data = plain.data(using: .utf8),
              let cipher = SecKeyCreateEncryptedData(
                  key, .rsaEncryptionPKCS1, data as CFData, &err
              ) else {
            let msg = err?.takeRetainedValue().localizedDescription ?? "未知错误"
            throw AppError.api("RSA 加密失败: \(msg)")
        }

        return (cipher as Data).base64EncodedString()
    }

    // ------------------------------------------------------------------
    // 登录：SN + 密码 -> token
    // ------------------------------------------------------------------
    func login(sn rawSn: String, password: String) async throws -> PgyAccount {
        let sn = rawSn.filter { !$0.isWhitespace }
        guard !sn.isEmpty, !password.isEmpty else {
            throw AppError.input("请输入 SN 码和密码")
        }

        // 1. 取公钥
        guard let pubURL = URL(string: loginBase + "/authorization/publickey") else {
            throw AppError.api("公钥地址错误")
        }
        let (pubData, pubResp) = try await session.data(from: pubURL)
        guard let http = pubResp as? HTTPURLResponse, http.statusCode == 200 else {
            throw AppError.network("获取登录公钥失败")
        }
        let pj = asDict(pubData)
        guard let b64 = (pj["public_key"] as? String) ?? (pj["publickey"] as? String),
              let pemData = Data(base64Encoded: b64),
              let pem = String(data: pemData, encoding: .utf8) else {
            throw AppError.api("获取登录公钥失败")
        }

        // 2. RSA 加密密码
        let pwdB64 = try rsaEncrypt(pem: pem, plain: password)

        // 3. 提交登录
        var req = URLRequest(url: URL(string: loginBase + "/authorization/login")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(appId, forHTTPHeaderField: "X-AppId")
        req.setValue("https://www.pgybox.com", forHTTPHeaderField: "Origin")
        req.setValue("https://www.pgybox.com/", forHTTPHeaderField: "Referer")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "sn": sn, "password": pwdB64, "is_rsa": true
        ])

        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let j = asDict(data)

        var result: [String: Any]? = nil
        if let d = j["data"] as? [String: Any] { result = d }
        else if j["access_token"] != nil { result = j }

        guard (status == 200 || status == 201), let r = result else {
            let code = String(describing: j["code"] ?? "")
            let msg = errorText[code]
                ?? (j["error"] as? String)
                ?? "登录失败 HTTP \(status)"
            throw AppError.api(msg)
        }

        let token = (r["access_token"] as? String) ?? (r["token"] as? String) ?? ""
        guard !token.isEmpty else { throw AppError.api("登录返回缺少 access_token") }

        return PgyAccount(
            sn: sn,
            accessToken: token,
            refreshToken: r["refresh_token"] as? String ?? "",
            refreshExpires: (r["refresh_expires"] as? NSNumber)?.int64Value ?? 0
        )
    }

    // ------------------------------------------------------------------
    // 刷新 token
    // ------------------------------------------------------------------
    func refresh(_ account: inout PgyAccount) async throws {
        var req = URLRequest(url: URL(string: authBase + "/authorize/refreshing")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(appId, forHTTPHeaderField: "X-AppId")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "access_token": account.accessToken,
            "refresh_token": account.refreshToken
        ])

        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw AppError.api("续期失败")
        }
        let d = asDict(data)
        let token = (d["access_token"] as? String) ?? (d["token"] as? String) ?? ""
        guard !token.isEmpty else { throw AppError.api("续期返回缺少 access_token") }
        account.accessToken = token
        account.refreshToken = (d["refresh_token"] as? String) ?? account.refreshToken
        if let e = d["refresh_expires"] as? NSNumber { account.refreshExpires = e.int64Value }
    }

    /// 距过期不足 5 分钟或已过期则续期
    func ensureValid(_ account: inout PgyAccount) async throws {
        let exp = jwtExp(account.accessToken)
        let now = Int64(Date().timeIntervalSince1970)
        if exp == 0 || exp - now < 300 {
            try await refresh(&account)
        }
    }

    // ------------------------------------------------------------------
    // 设备列表 / 开机
    // ------------------------------------------------------------------
    private func headers(_ account: PgyAccount) -> [String: String] {
        var h = ["Accept": "application/json", "X-AppId": appId]
        if !account.accessToken.isEmpty {
            h["Authorization"] = "Bearer " + account.accessToken
        }
        return h
    }

    func listDevices(_ account: PgyAccount) async throws -> [PgyDevice] {
        var comps = URLComponents(string: apiBase + "/oraybox/wakeup/device")!
        comps.queryItems = [
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "pagesize", value: "10")
        ]
        var req = URLRequest(url: comps.url!)
        headers(account).forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }

        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw AppError.api("登录凭证已失效，请重新登录") }
        guard status == 200 else { throw AppError.api("获取设备列表失败 HTTP \(status)") }

        let j = asDict(data)
        guard let arr = j["list"] as? [[String: Any]] else { return [] }
        let decoder = JSONDecoder()
        return arr.compactMap { dict in
            guard let d = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
            return try? decoder.decode(PgyDevice.self, from: d)
        }
    }

    func wake(_ account: PgyAccount, mac: String) async throws {
        var req = URLRequest(url: URL(string: apiBase + "/oraybox/wakeup/wol")!)
        req.httpMethod = "PUT"
        var h = headers(account)
        h["Content-Type"] = "application/json"
        h.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        req.httpBody = try JSONSerialization.data(withJSONObject: ["mac": mac])

        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw AppError.api("登录凭证已失效，请重新登录") }
        guard status == 200 || status == 204 else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw AppError.api("开机接口返回 HTTP \(status): \(String(text.prefix(160)))")
        }
    }
}
