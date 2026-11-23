# 远程开机 · 功率监控（iOS / TrollStore 版）

把 Windows 上那两个 Python 程序（蒲公英远程开机 + 机智云功率监控）用 Swift 重写成的原生 iOS App，
可在巨魔（TrollStore）越狱的 iPhone / iPad 上安装使用。

## 工作原理

iOS 应用无法编译 Python，也不允许直接运行脚本，因此核心逻辑已全部用 Swift 原生重写：

| Windows 原版 | iOS 版 |
|---|---|
| tkinter 界面 | SwiftUI 原生界面 |
| Windows DPAPI 加密密码 | iOS Keychain（本机安全存储） |
| requests + cryptography | URLSession + Security.framework（RSA PKCS1v15） |
| 内置 socket WebSocket | URLSessionWebSocketTask |
| gizwits_power.py | GizwitsService.swift（解析逻辑逐条对齐） |
| pgy_wakeup_gui.py | PgyService.swift + WakeView.swift |

编译在 GitHub 的免费 macOS 云主机上完成（本机 Windows 无法产出 IPA），
再用 `ldid` 做伪签名，产物可被 TrollStore 直接安装。

## 如何拿到 IPA（全程不需要 Mac）

### 最快方式：双击一键脚本

直接**双击 `build-ipa.bat`**，它会：
1. 首次运行时打开浏览器让你登录 GitHub（只需一次）
2. 自动建仓库、上传代码、启动云端编译
3. 编译完成后自动把 IPA 下载到你的桌面

全程约 5 分钟，你只需要登录那一步。

### 手动方式

#### 1. 新建 GitHub 仓库
打开 https://github.com/new ，起个名字（例如 `wakeup-ios`），
选择 **Public**（私有仓库也能编译，但 Release 下载链接公开更方便），
**不要**勾选初始化 README，点 Create repository。

### 2. 上传工程
把本目录里的这些文件上传到仓库根目录（保持目录结构）：

```
.github/workflows/build.yml
WakeUpIOS/AppState.swift
WakeUpIOS/Common.swift
WakeUpIOS/GizwitsService.swift
WakeUpIOS/PgyService.swift
WakeUpIOS/PowerView.swift
WakeUpIOS/WakeUpApp.swift
WakeUpIOS/WakeView.swift
entitlements.plist
project.yml
```

网页上传时可以先建好同名文件夹再拖进去；或者直接把 `WakeUpIOS.zip` 解压后全选拖进仓库。

### 3. 等待自动编译
上传后进入仓库的 **Actions** 标签页，会看到 `Build TrollStore IPA` 正在运行。
绿色对勾表示成功（首次约 3~5 分钟）。若失败，点进去看日志，把红色报错发给我。

### 4. 下载 IPA
两种方式任选：
- **Actions 制品**：点进这次运行，页面底部 Artifacts 里下载 `WakeUpPower-TrollStore`（是个 zip，解压得到 .ipa）
- **Release 直装链接**：进入 **Releases**，有一个 `latest` 版本，里面有 IPA 和一条 `apple-magnifier://install?url=...` 的链接

### 5. 巨魔安装
- 在手机上用 Safari 打开那条 `apple-magnifier://install?url=...` 链接，会自动跳转 TrollStore 安装；
- 或者把 IPA 传到手机「文件」App，共享 → 用 TrollStore 打开。

装好后桌面出现「远程开机·功率」图标。

## 功能

- **远程开机**：SN 码 + 密码登录（RSA 加密传输）、多账号切换、记住密码、设备列表、一键开机、token 自动续期
- **功率监控**：机智云账号登录、设备切换、数码管大屏实时功率、电压/电流/电量/功率因数/频率、WebSocket 实时推送 + 5 秒轮询兜底、登录态自动恢复

支持 iOS 15.0 及以上（TrollStore 要求 iOS 14.0 beta 2 ~ 16.6.1 / 16.7 RC / 17.0）。

## 已知差异与限制

- iOS 的 TLS 栈无法像 Python 那样手动把 cipher 降到 `SECLEVEL=0`。如果机智云老服务器因 TLS  cipher 问题连不上，`NSAllowsArbitraryLoads` 已放宽 ATS，但极端情况下仍可能需要在服务端更新证书。蒲公英接口是标准 TLS，不受影响。
- WebSocket 对机智云自签证书做了放宽校验（与 Windows 版 `rejectUnauthorized:false` 一致）。
- 巨魔安装的 App 签名有效期由 TrollStore 管理，重启后若图标变灰，在 TrollStore 里点「Refresh」重新注册即可。

## 常见问题

- **Actions 一直转圈**：GitHub 免费 runners 高峰期会排队，等几分钟即可。
- **`ldid` 相关报错**：确认 build.yml 里 `brew install xcodegen ldid` 那步成功。
- **装上闪退**：把设备 iOS 版本和闪退截图发我；先确认 TrollStore 版本 ≥ 2.0。
