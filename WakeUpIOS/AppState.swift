import Foundation
import Combine

/// 全局状态：账户持久化 + 设备列表 + 功率读数
final class AppState: ObservableObject {
    static let shared = AppState()

    // 蒲公英
    @Published var pgyAccounts: [PgyAccount] = []
    @Published var activePgy: PgyAccount?
    @Published var pgyDevices: [PgyDevice] = []

    // 机智云
    @Published var gizAccounts: [GizAccount] = []
    @Published var activeGiz: GizAccount?
    @Published var gizDevices: [GizDevice] = []
    @Published var reading: PowerReading?
    @Published var gizStatus: String = ""
    @Published var maxPowerW: Double? = nil
    @Published var minPowerW: Double? = nil
    @Published var powerHistory: [Double] = []

    /// 追加一条功率记录，最多保留 60 条
    func appendPowerHistory(_ value: Double) {
        powerHistory.append(value)
        if powerHistory.count > 60 {
            powerHistory.removeFirst(powerHistory.count - 60)
        }
    }

    func clearPowerHistory() {
        powerHistory.removeAll()
    }

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() { loadAll() }

    // ------------------------------------------------------------------
    // 持久化（密码存 Keychain，账户其他信息存 UserDefaults）
    // ------------------------------------------------------------------
    func loadAll() {
        if let d = UserDefaults.standard.data(forKey: "pgy.accounts"),
           let arr = try? decoder.decode([PgyAccount].self, from: d) {
            pgyAccounts = arr
        }
        let activeSn = UserDefaults.standard.string(forKey: "pgy.active") ?? ""
        activePgy = pgyAccounts.first(where: { $0.sn == activeSn })

        if let d = UserDefaults.standard.data(forKey: "giz.accounts"),
           let arr = try? decoder.decode([GizAccount].self, from: d) {
            gizAccounts = arr
        }
        let activeUser = UserDefaults.standard.string(forKey: "giz.active") ?? ""
        activeGiz = gizAccounts.first(where: { $0.username == activeUser })
    }

    func savePgy() {
        let arr = pgyAccounts.map { a -> PgyAccount in
            var x = a; x.password = ""; return x
        }
        if let d = try? encoder.encode(arr) {
            UserDefaults.standard.set(d, forKey: "pgy.accounts")
        }
        UserDefaults.standard.set(activePgy?.sn ?? "", forKey: "pgy.active")
    }

    func saveGiz() {
        let arr = gizAccounts.map { a -> GizAccount in
            var x = a; x.password = ""; return x
        }
        if let d = try? encoder.encode(arr) {
            UserDefaults.standard.set(d, forKey: "giz.accounts")
        }
        UserDefaults.standard.set(activeGiz?.username ?? "", forKey: "giz.active")
    }

    // ------------------------------------------------------------------
    // 蒲公英账户
    // ------------------------------------------------------------------
    func pgyPassword(for sn: String) -> String {
        KeychainStore.get("pgy.\(sn)") ?? ""
    }

    func upsertPgy(_ account: PgyAccount, password: String, remember: Bool) {
        var a = account
        a.rememberPassword = remember
        // 始终保存密码到 Keychain，便于 token 过期后自动重新登录
        KeychainStore.set(password, forKey: "pgy.\(a.sn)")
        if let i = pgyAccounts.firstIndex(where: { $0.sn == a.sn }) {
            pgyAccounts[i] = a
        } else {
            pgyAccounts.append(a)
        }
        activePgy = a
        savePgy()
    }

    func removePgy(sn: String) {
        pgyAccounts.removeAll { $0.sn == sn }
        KeychainStore.delete("pgy.\(sn)")
        if activePgy?.sn == sn { activePgy = pgyAccounts.first }
        savePgy()
    }

    // ------------------------------------------------------------------
    // 机智云账户
    // ------------------------------------------------------------------
    func gizPassword(for username: String) -> String {
        KeychainStore.get("giz.\(username)") ?? ""
    }

    func upsertGiz(_ account: GizAccount, password: String, remember: Bool) {
        var a = account
        a.rememberPassword = remember
        // 始终保存密码到 Keychain，便于 token 过期后自动重新登录
        KeychainStore.set(password, forKey: "giz.\(a.username)")
        if let i = gizAccounts.firstIndex(where: { $0.username == a.username }) {
            gizAccounts[i] = a
        } else {
            gizAccounts.append(a)
        }
        activeGiz = a
        saveGiz()
    }

    func removeGiz(username: String) {
        gizAccounts.removeAll { $0.username == username }
        KeychainStore.delete("giz.\(username)")
        if activeGiz?.username == username { activeGiz = gizAccounts.first }
        saveGiz()
    }
}
