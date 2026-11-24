import SwiftUI
import Foundation

// ======================================================================
// 合并首页：远程开机 + 功率监控，单页面双卡片
// ======================================================================
struct MainView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var gizService = GizwitsService.shared

    // -- 远程开机状态 --
    @State private var wakeSn = ""
    @State private var wakePassword = ""
    @State private var wakeRemember = true
    @State private var wakeBusy = false
    @State private var wakeMessage = "请输入路由器 SN 码和密码"
    @State private var wakeSelectedMac: String? = nil
    @State private var wakeAlertText: String? = nil
    @State private var wakeExpanded = false

    // -- 功率监控状态 --
    @State private var powerUsername = ""
    @State private var powerPassword = ""
    @State private var powerRemember = true
    @State private var powerBusy = false
    @State private var powerSelectedDid: String? = nil
    @State private var powerAlertText: String? = nil
    @State private var powerTimer: Timer? = nil
    @State private var powerExpanded = false
    @State private var blinkOn = true

    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    private let blinkPub = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // ============================================================
                // 卡片 1：远程开机
                // ============================================================
                wakeCard
                    .padding(.horizontal)

                // ============================================================
                // 卡片 2：功率监控
                // ============================================================
                powerCard
                    .padding(.horizontal)
            }
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .alert("提示", isPresented: Binding(
            get: { wakeAlertText != nil },
            set: { if !$0 { wakeAlertText = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(wakeAlertText ?? "")
        }
        .onReceive(timer) { _ in powerPoll() }
        .onAppear {
            if wakeSn.isEmpty, let a = state.activePgy {
                wakeSn = a.sn
                if a.rememberPassword { wakePassword = state.pgyPassword(for: a.sn) }
            }
            if powerUsername.isEmpty, let a = state.activeGiz {
                powerUsername = a.username
                if a.rememberPassword { powerPassword = state.gizPassword(for: a.username) }
            }
            gizService.onReading = { r in
                DispatchQueue.main.async {
                    state.reading = r
                    if let p = r.powerW, p.isFinite {
                        if state.maxPowerW == nil || p > state.maxPowerW! { state.maxPowerW = p }
                        if state.minPowerW == nil || p < state.minPowerW! { state.minPowerW = p }
                        state.appendPowerHistory(p)
                    }
                }
            }
            gizService.onError = { msg in
                DispatchQueue.main.async { state.gizStatus = msg }
            }
        }
        .onReceive(blinkPub) { _ in blinkOn.toggle() }
        .onDisappear { gizService.stop() }
    }

    // ==================================================================
    // 远程开机卡片
    // ==================================================================
    private var wakeCard: some View {
        VStack(spacing: 0) {
            CardHeader(
                title: "远程开机",
                icon: "power.circle.fill",
                color: .orange,
                expanded: $wakeExpanded
            )

            if wakeExpanded {
                VStack(spacing: 12) {
                    if let account = state.activePgy, !account.accessToken.isEmpty {
                        wakeMainContent
                    } else {
                        wakeLoginContent
                    }
                }
                .padding(12)
            }
        }
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.06), radius: 8, y: 4)
    }

    private var wakeLoginContent: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("SN 码").frame(width: 50, alignment: .trailing)
                    TextField("路由器 SN 码", text: $wakeSn)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                HStack {
                    Text("密码").frame(width: 50, alignment: .trailing)
                    SecureField("设备密码", text: $wakePassword)
                        .textFieldStyle(.roundedBorder)
                }
                Toggle("记住 SN 码和密码", isOn: $wakeRemember)
                    .font(.caption).foregroundColor(.secondary)

                if !state.pgyAccounts.isEmpty {
                    Menu("选择已保存账户") {
                        ForEach(state.pgyAccounts) { a in
                            Button(a.sn) {
                                wakeSn = a.sn
                                wakePassword = a.rememberPassword ? state.pgyPassword(for: a.sn) : ""
                            }
                        }
                    }
                }
            }

            Button { doWakeLogin() } label: {
                if wakeBusy { ProgressView() }
                else { Text("登 录").font(.headline) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(wakeBusy || wakeSn.isEmpty || wakePassword.isEmpty)

            Text(wakeMessage)
                .font(.caption).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var wakeMainContent: some View {
        VStack(spacing: 10) {
            HStack {
                Menu {
                    ForEach(state.pgyAccounts) { a in
                        Button(a.sn) {
                            state.activePgy = a
                            state.savePgy()
                            wakeSn = a.sn
                            wakePassword = a.rememberPassword ? state.pgyPassword(for: a.sn) : ""
                            Task { await loadWakeDevices() }
                        }
                    }
                } label: {
                    Label(state.activePgy?.sn ?? "账户", systemImage: "person.circle")
                        .font(.caption)
                }
                Button { Task { await loadWakeDevices() } } label: {
                    Image(systemName: "arrow.clockwise")
                }.font(.caption)
                    .disabled(wakeBusy)
                Spacer()
                Button("退出") { wakeLogout() }.font(.caption)
            }

            if state.pgyDevices.isEmpty {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("正在获取设备列表...").font(.caption).foregroundColor(.secondary)
                }
            } else {
                List(state.pgyDevices, id: \.mac, selection: $wakeSelectedMac) { dev in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text((dev.hostname ?? "").isEmpty ? "未命名设备" : dev.hostname!)
                                .font(.subheadline)
                            Text(dev.mac).font(.caption.monospaced()).foregroundColor(.secondary)
                        }
                        Spacer()
                        Text(dev.isonline ? "在线" : "离线")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(dev.isonline ? Color.green.opacity(0.15) : Color.gray.opacity(0.15))
                            .cornerRadius(6)
                            .foregroundColor(dev.isonline ? .green : .secondary)
                    }
                }
                .listStyle(.plain)
                .frame(height: 120)

                HStack {
                    Text(wakeMessage).font(.caption).foregroundColor(.secondary)
                    Spacer()
                }
                Button {
                    if let mac = wakeSelectedMac { doWake(mac: mac) }
                    else { wakeAlertText = "请先在列表中选中一台设备" }
                } label: {
                    if wakeBusy { ProgressView() }
                    else { Label("开 机", systemImage: "power") }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .disabled(wakeBusy)
            }
        }
    }

    // ==================================================================
    // 功率监控卡片
    // ==================================================================
    private var powerCard: some View {
        VStack(spacing: 0) {
            CardHeader(
                title: "功率监控",
                icon: "bolt.fill",
                color: .green,
                expanded: $powerExpanded
            )

            if powerExpanded {
                VStack(spacing: 12) {
                    if let account = state.activeGiz, !account.token.isEmpty {
                        powerMainContent
                    } else {
                        powerLoginContent
                    }
                }
                .padding(12)
            }
        }
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.06), radius: 8, y: 4)
    }

    private var powerLoginContent: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("用户名").frame(width: 50, alignment: .trailing)
                    TextField("手机号 / 账号", text: $powerUsername)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                HStack {
                    Text("密码").frame(width: 50, alignment: .trailing)
                    SecureField("密码", text: $powerPassword)
                        .textFieldStyle(.roundedBorder)
                }
                Toggle("记住用户名和密码", isOn: $powerRemember)
                    .font(.caption).foregroundColor(.secondary)

                if !state.gizAccounts.isEmpty {
                    Menu("选择已保存账户") {
                        ForEach(state.gizAccounts) { a in
                            Button(a.username) {
                                powerUsername = a.username
                                powerPassword = a.rememberPassword ? state.gizPassword(for: a.username) : ""
                            }
                        }
                    }
                }
            }

            Button { doPowerLogin() } label: {
                if powerBusy { ProgressView() }
                else { Text("登 录").font(.headline) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(powerBusy || powerUsername.isEmpty || powerPassword.isEmpty)

            let statusText = state.gizStatus.isEmpty ? "请输入机智云账号" : state.gizStatus
            Text(statusText)
                .font(.caption).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var powerMainContent: some View {
        VStack(spacing: 10) {
            HStack {
                Picker("设备", selection: $powerSelectedDid) {
                    ForEach(state.gizDevices) { d in
                        Text(d.label).tag(Optional(d.did))
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: powerSelectedDid) { new in
                    if let did = new { powerStartMonitor(did: did) }
                }
                Button { Task { await loadPowerDevices() } } label: {
                    Image(systemName: "arrow.clockwise")
                }.font(.caption)
                    .disabled(powerBusy)
                Spacer()
                Button("退出") { powerLogout() }.font(.caption)
            }

            if state.gizDevices.isEmpty {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("正在获取设备列表...").font(.caption).foregroundColor(.secondary)
                }
            } else {
                powerDisplayPanel

                HStack {
                    Text(state.gizStatus.isEmpty ? gizService.connectionMode : state.gizStatus)
                        .font(.caption).foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
    }

    private var powerDisplayPanel: some View {
        let r = state.reading
        return ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(red: 0.05, green: 0.07, blue: 0.09))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(white: 0.18), lineWidth: 1)
                )

            VStack(spacing: 8) {
                // 状态指示灯 + 连接状态
                HStack(spacing: 6) {
                    statusDot
                    Text(statusText)
                        .font(.caption2)
                        .foregroundColor(.gray)
                    Spacer()
                }

                if let p = r?.powerW {
                    Text(String(format: "%.1f", p))
                        .font(.system(size: 52, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(red: 0.18, green: 1.0, blue: 0.42))
                        .shadow(color: Color.green.opacity(0.45), radius: 10)
                        .minimumScaleFactor(0.5)
                } else {
                    Text("--.-")
                        .font(.system(size: 52, weight: .bold, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.35))
                }

                Text("W（有功功率）")
                    .font(.caption2)
                    .foregroundColor(.gray)

                // 功率波形图（黄色半透明、圆滑曲线）
                powerWaveform

                Divider().background(Color(white: 0.15)).padding(.vertical, 2)

                // MAX / MIN 功率
                HStack(spacing: 16) {
                    powerStat("MAX", state.maxPowerW)
                    powerStat("LOW", state.minPowerW)
                }

                HStack(spacing: 12) {
                    powerMetric("电压", r?.voltageV, 1, "V")
                    powerMetric("电流", r?.currentA, 3, "A")
                    powerMetric("电量", r?.energyKwh, 2, "kWh")
                    powerMetric("功率因数", r?.powerFactor, 3, "")
                    powerMetric("频率", r?.freqHz, 1, "Hz")
                }
                .font(.caption2)
            }
            .padding(8)
        }
        .frame(height: 330)
    }

    // 功率波形图：黄色半透明，Catmull-Rom 圆滑曲线
    private var powerWaveform: some View {
        let history = state.powerHistory
        let w: CGFloat = 240
        let h: CGFloat = 56

        if history.count < 2 {
            return AnyView(
                Text("等待数据...")
                    .font(.caption2)
                    .foregroundColor(.gray.opacity(0.5))
                    .frame(height: h)
            )
        }

        // 计算 y 轴范围，留适当边距
        let minV = history.min() ?? 0
        let maxV = history.max() ?? 1
        let range = max(maxV - minV, 0.001)
        let padY: CGFloat = 6

        // 生成 Catmull-Rom 插值点
        let pts: [CGPoint] = {
            var result: [CGPoint] = []
            let n = history.count
            let step = w / CGFloat(n - 1)
            for i in 0..<(n - 1) {
                let t0 = Double(max(i - 1, 0))
                let t1 = Double(i)
                let t2 = Double(i + 1)
                let t3 = Double(min(i + 2, n - 1))
                // 采样 8 段以获得平滑曲线
                let segments = 8
                for s in 0...segments {
                    let t = CGFloat(s) / CGFloat(segments)
                    let tt = t
                    let p0x = (t0) * step
                    let p1x = (t1) * step
                    let p2x = (t2) * step
                    let p3x = (t3) * step

                    // Catmull-Rom 公式
                    let c1x = p1x + (p2x - p0x) / 6
                    let c2x = p2x - (p3x - p1x) / 6
                    let x = (1 - tt) * (1 - tt) * (1 - tt) * p1x +
                            3 * (1 - tt) * (1 - tt) * tt * c1x +
                            3 * (1 - tt) * tt * tt * c2x +
                            tt * tt * tt * p2x

                    let y1 = CGFloat(history[Int(t1)])
                    let y2 = CGFloat(history[Int(t2)])
                    let y0 = CGFloat(history[Int(t0)])
                    let y3 = CGFloat(history[Int(t3)])
                    let c1y = y1 + (y2 - y0) / 6
                    let c2y = y2 - (y3 - y1) / 6
                    let y = h - padY - ((1 - tt) * (1 - tt) * (1 - tt) * y1 +
                                       3 * (1 - tt) * (1 - tt) * tt * c1y +
                                       3 * (1 - tt) * tt * tt * c2y +
                                       tt * tt * tt * y2 - minV) / range * (h - 2 * padY)

                    result.append(CGPoint(x: x, y: y))
                }
            }
            return result
        }()

        let path = Path { p in
            if let first = pts.first {
                p.move(to: first)
                for pt in pts.dropFirst() {
                    p.addLine(to: pt)
                }
            }
        }

        return AnyView(
            Canvas { context, _ in
                // 填充区域（半透明黄色）
                var fillPath = path
                let last = pts.last!
                let first = pts.first!
                fillPath.addLine(to: CGPoint(x: last.x, y: h))
                fillPath.addLine(to: CGPoint(x: first.x, y: h))
                fillPath.closeSubpath()
                context.fill(fillPath, with: .color(Color.yellow.opacity(0.15)))

                // 曲线描边
                context.stroke(
                    path,
                    with: .color(Color.yellow.opacity(0.7)),
                    lineWidth: 1.5
                )
            }
            .frame(width: w, height: h)
        )
    }

    // 状态指示灯：实时推送=绿色闪烁，轮询=黄色，断开=红色
    private var statusDot: some View {
        let color: Color
        let blink: Bool
        switch gizService.connState {
        case .realtime:
            color = .green
            blink = true
        case .polling:
            color = .yellow
            blink = false
        case .disconnected:
            color = .red
            blink = false
        }
        return Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .opacity(blink ? (blinkOn ? 1.0 : 0.25) : 1.0)
            .shadow(color: color.opacity(0.6), radius: 4)
    }

    private var statusText: String {
        switch gizService.connState {
        case .realtime: return "实时推送"
        case .polling: return "轮询刷新"
        case .disconnected: return "连接断开"
        }
    }

    private func powerStat(_ label: String, _ value: Double?) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2.bold())
                .foregroundColor(.yellow)
            if let v = value {
                Text(String(format: "%.1f", v))
                    .foregroundColor(.yellow)
                    .monospacedDigit()
            } else {
                Text("--")
                    .foregroundColor(.gray.opacity(0.5))
            }
        }
    }

    private func powerMetric(_ name: String, _ value: Double?, _ digits: Int, _ unit: String) -> some View {
        VStack(spacing: 2) {
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

    // ==================================================================
    // 远程开机逻辑
    // ==================================================================
    private func doWakeLogin() {
        wakeBusy = true
        wakeMessage = "正在登录 ..."
        Task {
            do {
                let acc = try await PgyService.shared.login(sn: wakeSn, password: wakePassword)
                state.upsertPgy(acc, password: wakePassword, remember: wakeRemember)
                await loadWakeDevices()
            } catch {
                await MainActor.run { wakeAlertText = error.localizedDescription }
            }
            await MainActor.run { wakeBusy = false }
        }
    }

    private func loadWakeDevices() async {
        guard var acc = state.activePgy else { return }
        await MainActor.run { wakeBusy = true; wakeMessage = "正在获取设备列表 ..." }
        do {
            try await PgyService.shared.ensureValid(&acc)
            state.upsertPgy(acc, password: state.pgyPassword(for: acc.sn), remember: acc.rememberPassword)
            let list = try await PgyService.shared.listDevices(acc)
            await MainActor.run {
                state.pgyDevices = list
                if wakeSelectedMac == nil || !list.contains(where: { $0.mac == wakeSelectedMac }) {
                    wakeSelectedMac = list.first?.mac
                }
                wakeMessage = "共 \(list.count) 台设备，选中后点开机"
            }
        } catch {
            await MainActor.run { wakeMessage = error.localizedDescription }
        }
        await MainActor.run { wakeBusy = false }
    }

    private func doWake(mac: String) {
        wakeBusy = true
        wakeMessage = "正在向 \(mac) 发送开机指令 ..."
        Task {
            do {
                var acc = state.activePgy!
                try await PgyService.shared.ensureValid(&acc)
                state.upsertPgy(acc, password: state.pgyPassword(for: acc.sn), remember: acc.rememberPassword)
                try await PgyService.shared.wake(acc, mac: mac)
                await MainActor.run {
                    wakeBusy = false
                    wakeMessage = "已向设备 \(mac) 发送开机指令，电脑约 1~2 分钟后启动。"
                }
                await loadWakeDevices()
            } catch {
                await MainActor.run {
                    wakeBusy = false
                    wakeMessage = error.localizedDescription
                    wakeAlertText = error.localizedDescription
                }
            }
        }
    }

    private func wakeLogout() {
        if let sn = state.activePgy?.sn { state.removePgy(sn: sn) }
        state.pgyDevices = []
        wakeSelectedMac = nil
        wakePassword = ""
        wakeMessage = "请输入路由器 SN 码和密码"
    }

    // ==================================================================
    // 功率监控逻辑
    // ==================================================================
    private func doPowerLogin() {
        powerBusy = true
        state.gizStatus = "正在登录 ..."
        Task {
            do {
                try await gizService.login(username: powerUsername, password: powerPassword)
                let acc = GizAccount(username: powerUsername, uid: gizService.uid, token: gizService.token)
                state.upsertGiz(acc, password: powerPassword, remember: powerRemember)
                await loadPowerDevices()
            } catch {
                await MainActor.run { state.gizStatus = error.localizedDescription }
            }
            await MainActor.run { powerBusy = false }
        }
    }

    private func loadPowerDevices() async {
        await MainActor.run { powerBusy = true; state.gizStatus = "正在获取设备列表 ..." }
        do {
            if gizService.token.isEmpty, let acc = state.activeGiz {
                gizService.restore(uid: acc.uid, token: acc.token)
            }
            let list = try await gizService.listDevices()
            await MainActor.run { state.gizDevices = list }
            await MainActor.run {
                if powerSelectedDid == nil || !list.contains(where: { $0.id == powerSelectedDid }) {
                    powerSelectedDid = list.first?.did
                }
                state.gizStatus = "共 \(list.count) 台设备"
                powerBusy = false
                if let did = powerSelectedDid { powerStartMonitor(did: did) }
            }
        } catch {
            await MainActor.run { state.gizStatus = error.localizedDescription; powerBusy = false }
        }
    }

    private func powerStartMonitor(did: String) {
        state.maxPowerW = nil
        state.minPowerW = nil
        state.clearPowerHistory()
        gizService.subscribe(did: did)
        state.gizStatus = ""
        Task {
            if let r = try? await gizService.readPower(did: did) {
                await MainActor.run {
                    state.reading = r
                    if let p = r.powerW, p.isFinite {
                        state.maxPowerW = p
                        state.minPowerW = p
                    }
                }
            }
        }
    }

    private func powerPoll() {
        guard let did = powerSelectedDid, let acc = state.activeGiz, !acc.token.isEmpty else { return }
        Task {
            if let r = try? await gizService.readPower(did: did) {
                await MainActor.run { state.reading = r }
            }
        }
    }

    private func powerLogout() {
        gizService.stop()
        gizService.connState = .disconnected
        if let u = state.activeGiz?.username { state.removeGiz(username: u) }
        state.gizDevices = []
        state.reading = nil
        state.maxPowerW = nil
        state.minPowerW = nil
        powerSelectedDid = nil
        powerPassword = ""
        state.gizStatus = ""
    }
}

// ======================================================================
// 可折叠卡片头部
// ======================================================================
struct CardHeader: View {
    let title: String
    let icon: String
    let color: Color
    @Binding var expanded: Bool

    var body: some View {
        Button {
            expanded.toggle()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundColor(color)
                    .font(.title3)
                Text(title)
                    .font(.headline)
                Spacer()
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(12)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    MainView().environmentObject(AppState.shared)
}
