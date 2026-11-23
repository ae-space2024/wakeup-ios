import Foundation
import Combine

// ============================================================================
// MARK: - 机智云：数据模型
// ============================================================================

struct GizAccount: Codable, Identifiable {
    var username: String = ""
    var uid: String = ""
    var token: String = ""
    var rememberPassword: Bool = false
    var password: String = ""          // 存 Keychain
    var id: String { username }
}

struct GizDevice: Decodable, Identifiable {
    let did: String
    let devAlias: String?
    let isOnline: Bool?
    let host: String?
    let wssPort: Int?

    var id: String { did }
    var label: String { (devAlias?.isEmpty == false ? devAlias : nil) ?? did }

    enum CodingKeys: String, CodingKey {
        case did, host
        case devAlias  = "dev_alias"
        case isOnline  = "is_online"
        case wssPort   = "wss_port"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        did      = try c.decodeIfPresent(String.self, forKey: .did) ?? ""
        devAlias = try c.decodeIfPresent(String.self, forKey: .devAlias)
        host     = try c.decodeIfPresent(String.self, forKey: .host)
        if let n = try? c.decodeIfPresent(Int.self, forKey: .wssPort) {
            wssPort = n
        } else if let s = try? c.decodeIfPresent(String.self, forKey: .wssPort) {
            wssPort = s.flatMap { Int($0) }
        } else {
            wssPort = nil
        }
        if let b = try? c.decodeIfPresent(Bool.self, forKey: .isOnline) {
            isOnline = b
        } else if let n = try? c.decodeIfPresent(Int.self, forKey: .isOnline) {
            isOnline = (n ?? 0) != 0
        } else {
            isOnline = nil
        }
    }
}

struct PowerReading {
    var did: String = ""
    var powerW: Double?
    var voltageV: Double?
    var currentA: Double?
    var energyKwh: Double?
    var powerFactor: Double?
    var freqHz: Double?
    var phasePower: [String: Double] = [:]
    var timestamp: Date?
    var raw: [String: Any] = [:]
}

// ============================================================================
// MARK: - 机智云：服务（HTTP + WebSocket 实时推送）
// ============================================================================

final class GizwitsService: NSObject, ObservableObject {
    static let shared = GizwitsService()

    private let appId = "1d5b0ff021614f42a44954c362d65992"
    private let apiHost = "api.gizwits.com"

    @Published private(set) var uid: String = ""
    @Published private(set) var token: String = ""
    @Published private(set) var devices: [GizDevice] = []
    @Published private(set) var connectionMode: String = "未连接"

    var onReading: ((PowerReading) -> Void)?
    var onError: ((String) -> Void)?

    private var wsTask: URLSessionWebSocketTask?
    private var heartbeat: Timer?
    private var mergedAttrs: [String: Any] = [:]
    private var currentDid: String = ""
    private var stopped = false

    private lazy var httpSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        return URLSession(configuration: cfg)
    }()

    private lazy var wsSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    // ------------------------------------------------------------------
    // JSON -> PowerReading（数据点优先级与 Python 版完全一致）
    // ------------------------------------------------------------------
    private static func firstNumber(_ attrs: [String: Any], _ keys: [String]) -> Double? {
        for k in keys {
            guard let v = attrs[k] else { continue }
            let d: Double?
            if let n = v as? NSNumber {
                d = n.doubleValue
            } else if let s = v as? String {
                d = Double(s)
            } else {
                continue
            }
            if let x = d, x.isFinite { return x }
        }
        return nil
    }

    static func parseReading(did: String, attrs: [String: Any], updatedAt: Int64? = nil) -> PowerReading {
        var r = PowerReading(did: did, raw: attrs)
        r.powerW     = firstNumber(attrs, ["P_value_P1", "Pa_value", "P_value", "Pt_value", "P_value_P2"])
        r.voltageV   = firstNumber(attrs, ["U_value", "Ua_value"])
        r.currentA   = firstNumber(attrs, ["I_value_P1", "Ia_value", "I_value_P2"])

        if let wh = firstNumber(attrs, ["E_value", "Et_value", "Energy"]), wh >= 0, wh <= 1e9 {
            r.energyKwh = wh / 1000.0
        }
        if let pf = firstNumber(attrs, ["PF_value_P1", "PFa_value", "PF_value"]) {
            r.powerFactor = pf / 1000.0
        }
        r.freqHz = firstNumber(attrs, ["f_value"])

        for (phase, key) in [("A", "Pa_value"), ("B", "Pb_value"), ("C", "Pc_value")] {
            if let v = firstNumber(attrs, [key]) { r.phasePower[phase] = v }
        }
        if let u = updatedAt, u > 0 {
            r.timestamp = Date(timeIntervalSince1970: TimeInterval(u))
        }
        return r
    }

    // ------------------------------------------------------------------
    // HTTP
    // ------------------------------------------------------------------
    private func request(_ method: String, _ path: String,
                         body: [String: Any]? = nil,
                         token: String? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://" + apiHost + path)!)
        req.httpMethod = method
        req.setValue(appId, forHTTPHeaderField: "X-Gizwits-Application-Id")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let t = token { req.setValue(t, forHTTPHeaderField: "X-Gizwits-User-token") }
        if let b = body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: b)
        }

        let (data, resp) = try await httpSession.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let j = asDict(data)
        guard (200..<300).contains(status) else {
            let msg = (j["error_message"] as? String)
                ?? (j["detail_message"] as? String)
                ?? "HTTP \(status)"
            throw AppError.api(msg)
        }
        return j
    }

    func login(username: String, password: String) async throws {
        let j = try await request("POST", "/app/login", body: [
            "username": username, "password": password, "lang": "zh-cn"
        ])
        guard let t = j["token"] as? String, !t.isEmpty else {
            throw AppError.api("登录未返回 token")
        }
        await MainActor.run {
            self.token = t
            self.uid = (j["uid"] as? String) ?? ""
        }
    }

    /// 用本地已存的 uid/token 恢复会话（不重新登录）
    func restore(uid: String, token: String) {
        self.uid = uid
        self.token = token
    }

    func listDevices() async throws -> [GizDevice] {
        guard !token.isEmpty else { throw AppError.api("请先登录机智云") }
        var all: [GizDevice] = []
        var skip = 0
        let limit = 20
        let decoder = JSONDecoder()
        while true {
            let path = "/app/bindings?show_disabled=0&show_proto_ver=1&limit=\(limit)&skip=\(skip)"
            let j = try await request("GET", path, token: token)
            let arr = (j["devices"] as? [[String: Any]]) ?? []
            for d in arr {
                if let data = try? JSONSerialization.data(withJSONObject: d),
                   let dev = try? decoder.decode(GizDevice.self, from: data) {
                    all.append(dev)
                }
            }
            if arr.count < limit || skip > 500 { break }
            skip += limit
        }
        await MainActor.run { self.devices = all }
        return all
    }

    /// HTTP 轮询读一次（不依赖 token，与原 Python 版一致）
    func readPower(did: String) async throws -> PowerReading {
        let encoded = did.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? did
        let j = try await request("GET", "/app/devdata/\(encoded)/latest")
        let attrs = (j["attr"] as? [String: Any]) ?? [:]
        let updated = (j["updated_at"] as? NSNumber)?.int64Value
        return Self.parseReading(did: did, attrs: attrs, updatedAt: updated)
    }

    // ------------------------------------------------------------------
    // WebSocket 实时订阅
    // ------------------------------------------------------------------
    func subscribe(did: String) {
        stop()
        stopped = false
        currentDid = did
        mergedAttrs = [:]

        guard let dev = devices.first(where: { $0.did == did }) else {
            connectionMode = "轮询刷新（无 host）"
            onError?("设备不在绑定列表中，使用轮询模式")
            return
        }

        // host 可能已带端口，避免拼成 :8880:8880
        var host = dev.host ?? apiHost
        var port = dev.wssPort ?? 8880
        if let m = host.range(of: #":(\d{2,5})$"#, options: .regularExpression) {
            let p = String(String(host[m]).dropFirst())
            port = Int(p) ?? port
            host = String(host[..<m.lowerBound])
        }

        let url = URL(string: "wss://\(host):\(port)/ws/app/v1")!
        let task = wsSession.webSocketTask(with: url)
        wsTask = task
        task.resume()

        send(cmd: "login_req", data: [
            "appid": appId,
            "uid": uid,
            "token": token,
            "p0_type": "attrs_v4",
            "heartbeat_interval": 180,
            "auto_subscribe": false
        ])

        DispatchQueue.main.async {
            self.connectionMode = "实时推送"
            self.heartbeat = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
                self?.send(cmd: "ping", data: [:])
            }
        }
        receiveLoop()
    }

    private func send(cmd: String, data: Any) {
        guard let task = wsTask,
              let d = try? JSONSerialization.data(withJSONObject: ["cmd": cmd, "data": data]),
              let text = String(data: d, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    private func receiveLoop() {
        wsTask?.receive { [weak self] result in
            guard let self = self, !self.stopped else { return }
            switch result {
            case .success(let msg):
                if case .string(let text) = msg,
                   let d = text.data(using: .utf8),
                   let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    self.handleWS(j)
                }
                self.receiveLoop()
            case .failure:
                DispatchQueue.main.async {
                    self.connectionMode = "推送中断，轮询中"
                }
                self.onError?("WebSocket 断开，已切换到轮询")
                self.stop()
            }
        }
    }

    private func handleWS(_ msg: [String: Any]) {
        let cmd = msg["cmd"] as? String ?? ""
        let data = msg["data"] as? [String: Any] ?? [:]
        if cmd == "login_res" {
            if (data["success"] as? Bool) == true {
                send(cmd: "subscribe_req", data: [["did": currentDid]])
            } else {
                onError?("WS 登录失败: \(data)")
            }
        } else if cmd == "s2c_invalid_msg" {
            if (data["error_code"] as? NSNumber)?.intValue == 1009 {
                send(cmd: "login_req", data: [
                    "appid": appId, "uid": uid, "token": token,
                    "p0_type": "attrs_v4", "heartbeat_interval": 180, "auto_subscribe": false
                ])
            } else {
                onError?("WS 无效消息: \(data)")
            }
        } else if cmd == "s2c_noti" {
            guard (data["did"] as? String) == currentDid else { return }
            if let attrs = data["attrs"] as? [String: Any] {
                for (k, v) in attrs { mergedAttrs[k] = v }
                let r = Self.parseReading(did: currentDid, attrs: mergedAttrs)
                onReading?(r)
            }
        }
    }

    func stop() {
        stopped = true
        heartbeat?.invalidate()
        heartbeat = nil
        wsTask?.cancel()
        wsTask = nil
        if !currentDid.isEmpty {
            DispatchQueue.main.async { self.connectionMode = "轮询刷新" }
        }
    }
}

// ----------------------------------------------------------------------------
// MARK: - URLSessionDelegate：机智云 M2M 用自签证书，放宽校验（与 PC 版一致）
// ----------------------------------------------------------------------------
extension GizwitsService: URLSessionDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
