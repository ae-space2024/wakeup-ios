import SwiftUI
import Foundation

struct PowerView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var service = GizwitsService.shared

    @State private var username = ""
    @State private var password = ""
    @State private var remember = true
    @State private var busy = false
    @State private var selectedDid: String?
    @State private var alertText: String?

    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if let account = state.activeGiz, !account.token.isEmpty {
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
        .onReceive(timer) { _ in poll() }
        .onAppear {
            if username.isEmpty, let a = state.activeGiz {
                username = a.username
                if a.rememberPassword { password = state.gizPassword(for: a.username) }
            }
            service.onReading = { r in
                DispatchQueue.main.async { state.reading = r }
            }
            service.onError = { msg in
                DispatchQueue.main.async { state.gizStatus = msg }
            }
        }
        .onDisappear { service.stop() }
    }

    // ------------------------------------------------------------------
    // 登录页
    // ------------------------------------------------------------------
    private var loginView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "bolt.fill")
                .font(.system(size: 56))
                .foregroundColor(.green)
            Text("电能表功率监控")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("用户名").frame(width: 70, alignment: .trailing)
                    TextField("手机号 / 账号", text: $username)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                HStack {
                    Text("密码").frame(width: 70, alignment: .trailing)
                    SecureField("密码", text: $password)
                        .textFieldStyle(.roundedBorder)
                }
                Toggle("记住用户名和密码（本机安全存储）", isOn: $remember)
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                if !state.gizAccounts.isEmpty {
                    Menu("选择已保存账户") {
                        ForEach(state.gizAccounts) { a in
                            Button(a.username) {
                                username = a.username
                                password = a.rememberPassword ? state.gizPassword(for: a.username) : ""
                            }
                        }
                    }
                    .font(.subheadline)
                }
            }
            .padding(.horizontal)

            Button { doLogin() } label: {
                if busy { ProgressView() }
                else { Text("登 录").fontWeight(.semibold) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(busy || username.isEmpty || password.isEmpty)

            Text(state.gizStatus.isEmpty ? "请输入机智云（卓虎智能）账号" : state.gizStatus)
                .font(.footnote).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding()
    }

    // ------------------------------------------------------------------
    // 主界面
    // ------------------------------------------------------------------
    private var mainView: some View {
        VStack(spacing: 12) {
            HStack {
                Picker("设备", selection: $selectedDid) {
                    ForEach(state.gizDevices) { d in
                        Text(d.label).tag(Optional(d.did))
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: selectedDid) { new in
                    if let did = new { startMonitor(did: did) }
                }

                Spacer()
                Button { Task { await loadDevices() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(busy)
                Button("退出") { logout() }.font(.subheadline)
            }
            .padding(.horizontal)

            displayPanel
                .padding(.horizontal)

            HStack {
                Text(state.gizStatus.isEmpty ? service.connectionMode : state.gizStatus)
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal)

            Spacer()
        }
        .padding(.top, 8)
        .task {
            await loadDevices()
            if let did = selectedDid { startMonitor(did: did) }
        }
    }

    // ------------------------------------------------------------------
    // 数码管大屏
    // ------------------------------------------------------------------
    private var displayPanel: some View {
        let r = state.reading
        return ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.05, green: 0.07, blue: 0.09))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color(white: 0.18), lineWidth: 1)
                )

            VStack(spacing: 10) {
                if let p = r?.powerW {
                    Text(String(format: "%.1f", p))
                        .font(.system(size: 78, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(red: 0.18, green: 1.0, blue: 0.42))
                        .shadow(color: Color.green.opacity(0.45), radius: 14)
                        .minimumScaleFactor(0.5)
                } else {
                    Text("--.-")
                        .font(.system(size: 78, weight: .bold, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.35))
                }

                Text("W（有功功率）")
                    .font(.subheadline)
                    .foregroundColor(.gray)

                Divider().background(Color(white: 0.15)).padding(.vertical, 4)

                HStack(spacing: 18) {
                    metric("电压", r?.voltageV, 1, "V")
                    metric("电流", r?.currentA, 3, "A")
                    metric("电量", r?.energyKwh, 2, "kWh")
                    metric("功率因数", r?.powerFactor, 3, "")
                    metric("频率", r?.freqHz, 1, "Hz")
                }
                .font(.caption2)
            }
            .padding()
        }
        .frame(height: 280)
    }

    private func metric(_ name: String, _ value: Double?, _ digits: Int, _ unit: String) -> some View {
        VStack(spacing: 3) {
            Text(name).foregroundColor(.gray)
            if let v = value {
                Text(String(format: "%.\(digits)f", v) + unit)
                    .foregroundColor(.white)
                    .monospacedDigit()
            } else {
                Text("--").foregroundColor(.gray.opacity(0.5))
            }
        }
    }

    // ------------------------------------------------------------------
    // 业务逻辑
    // ------------------------------------------------------------------
    private func doLogin() {
        busy = true
        state.gizStatus = "正在登录 ..."
        Task {
            do {
                try await service.login(username: username, password: password)
                let acc = GizAccount(
                    username: username,
                    uid: service.uid,
                    token: service.token
                )
                state.upsertGiz(acc, password: password, remember: remember)
                await loadDevices()
            } catch {
                await MainActor.run { state.gizStatus = error.localizedDescription }
            }
            await MainActor.run { busy = false }
        }
    }

    private func loadDevices() async {
        await MainActor.run {
            busy = true
            state.gizStatus = "正在获取设备列表 ..."
        }
        do {
            if service.token.isEmpty, let acc = state.activeGiz {
                service.restore(uid: acc.uid, token: acc.token)
            }
            let list = try await service.listDevices()
            await MainActor.run { state.gizDevices = list }
            await MainActor.run {
                if selectedDid == nil || !list.contains(where: { $0.id == selectedDid }) {
                    selectedDid = list.first?.did
                }
                state.gizStatus = "共 \(list.count) 台设备"
                busy = false
                if let did = selectedDid { startMonitor(did: did) }
            }
        } catch {
            await MainActor.run {
                state.gizStatus = error.localizedDescription
                busy = false
            }
        }
    }

    private func startMonitor(did: String) {
        service.subscribe(did: did)
        state.gizStatus = ""
        Task {
            if let r = try? await service.readPower(did: did) {
                await MainActor.run { state.reading = r }
            }
        }
    }

    private func poll() {
        guard let did = selectedDid, let acc = state.activeGiz, !acc.token.isEmpty else { return }
        Task {
            if let r = try? await service.readPower(did: did) {
                await MainActor.run { state.reading = r }
            }
        }
    }

    private func logout() {
        service.stop()
        if let u = state.activeGiz?.username { state.removeGiz(username: u) }
        state.gizDevices = []
        state.reading = nil
        selectedDid = nil
        password = ""
        state.gizStatus = ""
    }
}
