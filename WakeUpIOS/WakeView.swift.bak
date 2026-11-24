import SwiftUI
import Foundation

struct WakeView: View {
    @EnvironmentObject var state: AppState
    @State private var sn = ""
    @State private var password = ""
    @State private var remember = true
    @State private var busy = false
    @State private var message = "请输入路由器 SN 码和密码"
    @State private var selectedMac: String?
    @State private var alertText: String?

    var body: some View {
        Group {
            if let account = state.activePgy, !account.accessToken.isEmpty {
                mainView
            } else {
                loginView
            }
        }
        .alert("提示", isPresented: Binding(
            get: { alertText != nil },
            set: { if !$0 { alertText = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(alertText ?? "")
        }
        .onAppear {
            if sn.isEmpty, let a = state.activePgy {
                sn = a.sn
                if a.rememberPassword { password = state.pgyPassword(for: a.sn) }
            }
        }
    }

    // ------------------------------------------------------------------
    // 登录页
    // ------------------------------------------------------------------
    private var loginView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "router.fill")
                .font(.system(size: 56))
                .foregroundColor(.accentColor)

            Text("蒲公英远程开机")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("SN 码").frame(width: 70, alignment: .trailing)
                    TextField("路由器 SN 码", text: $sn)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                HStack {
                    Text("密码").frame(width: 70, alignment: .trailing)
                    SecureField("设备密码", text: $password)
                        .textFieldStyle(.roundedBorder)
                }
                Toggle("记住 SN 码和密码（本机安全存储）", isOn: $remember)
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                if !state.pgyAccounts.isEmpty {
                    Menu("选择已保存账户") {
                        ForEach(state.pgyAccounts) { a in
                            Button(a.sn) {
                                sn = a.sn
                                password = a.rememberPassword ? state.pgyPassword(for: a.sn) : ""
                            }
                        }
                    }
                    .font(.subheadline)
                }
            }
            .padding(.horizontal)

            Button {
                doLogin()
            } label: {
                if busy { ProgressView() }
                else { Text("登 录").font(.headline) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(busy || sn.isEmpty || password.isEmpty)

            Text(message)
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding()
    }

    // ------------------------------------------------------------------
    // 主界面
    // ------------------------------------------------------------------
    private var mainView: some View {
        VStack(spacing: 0) {
            HStack {
                Menu {
                    ForEach(state.pgyAccounts) { a in
                        Button(a.sn) {
                            state.activePgy = a
                            state.savePgy()
                            sn = a.sn
                            password = a.rememberPassword ? state.pgyPassword(for: a.sn) : ""
                            Task { await loadDevices() }
                        }
                    }
                } label: {
                    Label(state.activePgy?.sn ?? "账户", systemImage: "person.circle")
                        .font(.subheadline)
                }
                Spacer()
                Button {
                    Task { await loadDevices() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(busy)
                Button("退出") { logout() }
                    .font(.subheadline)
            }
            .padding(.horizontal)
            .padding(.top, 8)

            List(state.pgyDevices, id: \.mac, selection: $selectedMac) { dev in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text((dev.hostname ?? "").isEmpty ? "未命名设备" : dev.hostname!)
                            .font(.headline)
                        Text(dev.mac).font(.caption.monospaced()).foregroundColor(.secondary)
                        Text("\(connText(dev.connType)) · \(dev.ip ?? "-")")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    Spacer()
                    Text(dev.isonline ? "在线" : "离线")
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(dev.isonline ? Color.green.opacity(0.18) : Color.gray.opacity(0.18))
                        .cornerRadius(8)
                        .foregroundColor(dev.isonline ? .green : .secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { selectedMac = dev.mac }
            }
            .listStyle(.inset)

            VStack(spacing: 8) {
                Text(message).font(.footnote).foregroundColor(.secondary)
                Button {
                    if let mac = selectedMac { doWake(mac: mac) }
                    else { alertText = "请先在列表中选中一台设备" }
                } label: {
                    if busy { ProgressView() }
                    else { Label("开 机", systemImage: "power").font(.headline) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .disabled(busy)
            }
            .padding()
        }
        .task { await loadDevices() }
    }

    private func connText(_ s: String?) -> String {
        switch s {
        case "eth": return "有线"
        case "wifi": return "无线"
        case "cellular": return "蜂窝"
        case let x?: return x
        default: return "-"
        }
    }

    // ------------------------------------------------------------------
    // 业务逻辑
    // ------------------------------------------------------------------
    private func doLogin() {
        busy = true
        message = "正在登录 ..."
        Task {
            do {
                let acc = try await PgyService.shared.login(sn: sn, password: password)
                state.upsertPgy(acc, password: password, remember: remember)
                await loadDevices()
            } catch {
                await MainActor.run { alertText = error.localizedDescription }
            }
            await MainActor.run { busy = false }
        }
    }

    private func loadDevices() async {
        guard var acc = state.activePgy else { return }
        await MainActor.run {
            busy = true
            message = "正在获取设备列表 ..."
        }
        do {
            try await PgyService.shared.ensureValid(&acc)
            state.upsertPgy(acc, password: state.pgyPassword(for: acc.sn), remember: acc.rememberPassword)
            let list = try await PgyService.shared.listDevices(acc)
            await MainActor.run {
                state.pgyDevices = list
                if selectedMac == nil || !list.contains(where: { $0.mac == selectedMac }) {
                    selectedMac = list.first?.mac
                }
                message = "共 \(list.count) 台设备，选中后点“开机”"
            }
        } catch {
            await MainActor.run {
                message = error.localizedDescription
                alertText = error.localizedDescription
            }
        }
        await MainActor.run { busy = false }
    }

    private func doWake(mac: String) {
        busy = true
        message = "正在向 \(mac) 发送开机指令 ..."
        Task {
            do {
                var acc = state.activePgy!
                try await PgyService.shared.ensureValid(&acc)
                state.upsertPgy(acc, password: state.pgyPassword(for: acc.sn), remember: acc.rememberPassword)
                try await PgyService.shared.wake(acc, mac: mac)
                await MainActor.run {
                    busy = false
                    alertText = "已向设备 \(mac) 发送开机指令。\n电脑约 1~2 分钟后启动。"
                }
                await loadDevices()
            } catch {
                await MainActor.run {
                    busy = false
                    message = error.localizedDescription
                    alertText = error.localizedDescription
                }
            }
        }
    }

    private func logout() {
        if let sn = state.activePgy?.sn { state.removePgy(sn: sn) }
        state.pgyDevices = []
        selectedMac = nil
        password = ""
        message = "请输入路由器 SN 码和密码"
    }
}
