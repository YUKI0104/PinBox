// 设置模型 + 持久化 + 对外动作
import AppKit
import Combine

struct TargetSpec: Codable, Equatable {
    var bundleID: String?
    var appName: String?
    var titleContains: String?
    var windowID: UInt32?

    init(from info: WindowInfo) {
        bundleID = info.bundleID
        appName = info.appName
        titleContains = info.title.isEmpty ? nil : info.title
        windowID = info.id
    }

    var displayName: String {
        let app = appName ?? "未选择"
        guard let t = titleContains, !t.isEmpty else { return app }
        return "\(app) — \(t)"
    }
}

@MainActor
final class AppController: ObservableObject {

    // ---- 设置（改动即存盘并应用到浮窗）----
    @Published var target: TargetSpec? { didSet { changed() ; engine?.reloadTarget() } }
    @Published var cropTop: Double = 0 { didSet { cropChanged() } }
    @Published var cropRight: Double = 0 { didSet { cropChanged() } }
    @Published var cropBottom: Double = 0 { didSet { cropChanged() } }
    @Published var cropLeft: Double = 0 { didSet { cropChanged() } }
    /// 每个 App 记住自己的裁切值 bundleID -> [上,右,下,左]
    @Published var cropByApp: [String: [Double]] = [:]
    @Published var opacity: Double = 1 { didSet { changed() } }
    @Published var cornerRadius: Double = 10 { didSet { changed() } }
    @Published var showBorder = true { didSet { changed() } }
    @Published var levelName = "floating" { didSet { changed() } }
    @Published var fps = 30 { didSet { changed() } }
    @Published var autoFollow = true { didSet { changed() } }
    @Published var autoReconnect = true { didSet { changed() } }
    @Published var showFloating = true { didSet { changed(); engine?.applyVisibility() } }
    @Published var launchAtLogin = false { didSet { changed(); applyLaunchAtLogin() } }

    // ---- 运行时状态（不持久化）----
    @Published var statusText = "未启动"
    @Published var sourceText = "未选择窗口"
    @Published var sourceSizeText = ""
    @Published var preview: CGImage?
    @Published var granted = ScreenPermission.granted
    @Published var axGranted = AX.trusted
    @Published var windows: [WindowInfo] = []
    @Published var showWindowList = false

    private(set) var engine: Engine?
    private var isLoading = true          // 加载设置期间的赋值不触发副作用
    /// 刚选了新窗口：连上后自动识别并裁掉标题栏
    private var pendingAutoCrop = false

    /// 设置项变化：存盘 + 应用到浮窗
    private func changed() {
        guard !isLoading else { return }
        save()
        engine?.applySettings()
    }

    /// 裁切变化：先记进该 App 的记忆，再存盘并应用
    private func cropChanged() {
        guard !isLoading else { return }
        if let b = target?.bundleID { cropByApp[b] = [cropTop, cropRight, cropBottom, cropLeft] }
        save()
        engine?.applySettings()
    }

    private func setCrop(_ v: [Double]) {
        let was = isLoading
        isLoading = true
        cropTop = v[0]; cropRight = v[1]; cropBottom = v[2]; cropLeft = v[3]
        isLoading = was
    }

    // MARK: 生命周期

    init() {
        load()
        isLoading = false
        spawnEngine()
    }

    private func spawnEngine() {
        engine = Engine(controller: self)
    }

    func start() {
        engine?.start()
        if !ScreenPermission.granted {
            statusText = "需要「屏幕录制」权限"
        }
    }

    func shutdown() {
        engine?.stop()
    }

    // MARK: 动作

    func refreshWindows() {
        Task {
            do {
                let result = try await WindowCatalog.fetch()
                windows = result.infos
                if statusText == "搜索中…" { statusText = "共 \(windows.count) 个窗口" }
            } catch {
                statusText = "枚举窗口失败：\(error.localizedDescription)"
            }
        }
    }

    func pick(_ info: WindowInfo) {
        // 同一个 App 再选一次不要丢掉之前调好的裁切；新 App 才从 0 开始
        let hadSaved = cropByApp[info.bundleID] != nil
        let saved = cropByApp[info.bundleID] ?? [0, 0, 0, 0]
        setCrop(saved)
        target = TargetSpec(from: info)          // 触发 reloadTarget
        cropByApp[info.bundleID] = saved
        pendingAutoCrop = !hadSaved && AX.trusted
        save()
        statusText = "已选择 \(info.displayName)"
    }

    /// 引擎连上之后回调
    func didConnect(_ info: WindowInfo, sourceSize: CGSize) {
        guard pendingAutoCrop else { return }
        pendingAutoCrop = false
        guard let h = AX.chromeHeight(pid: info.pid, matchingTitle: info.title, windowSize: sourceSize),
              h > 4 else { return }
        cropTop = Double(h)
        statusText = "已自动裁掉顶部 \(Int(h))pt 标题栏（可在设置里微调）"
    }

    /// 用关闭按钮位置反推标题栏/工具栏高度
    func autoCropChrome() {
        guard AX.trusted else {
            AX.requestTrust()
            axGranted = AX.trusted
            statusText = "自动识别需要「辅助功能」权限，授权后再点一次"
            return
        }
        let srcSize = engine?.currentSourceSize ?? .zero
        guard srcSize.height > 0,
              let info = windows.first(where: { $0.id == engine?.currentSourceID }) else {
            statusText = "先选中一个窗口"
            return
        }
        if let h = AX.chromeHeight(pid: info.pid, matchingTitle: info.title, windowSize: srcSize) {
            cropTop = Double(h)
            statusText = "已自动裁掉顶部 \(Int(h))pt"
        } else {
            statusText = "没识别出来，请手动调裁切数值"
        }
    }

    func resetFrame() {
        engine?.resetFrame()
        statusText = "浮窗位置已重置"
    }

    func requestScreenPermission() {
        ScreenPermission.request()
        granted = ScreenPermission.granted
        if granted {
            statusText = "权限已授予，正在重连…"
            engine?.reloadTarget()
        } else {
            ScreenPermission.openSettings()
            statusText = "请在系统设置中勾选 PinBox，然后回到这里"
        }
    }

    private func applyLaunchAtLogin() {
        guard !isLoading else { return }
        do {
            if launchAtLogin {
                try LaunchAtLogin.register()
            } else {
                try LaunchAtLogin.unregister()
            }
        } catch {
            statusText = "开机自启设置失败：\(error.localizedDescription)"
        }
    }

    func syncPermissionState() {
        granted = ScreenPermission.granted
        axGranted = AX.trusted
    }

    // MARK: 持久化

    private struct Persisted: Codable {
        var target: TargetSpec?
        var cropTop: Double = 0
        var cropRight: Double = 0
        var cropBottom: Double = 0
        var cropLeft: Double = 0
        var opacity: Double = 1
        var cornerRadius: Double = 10
        var showBorder: Bool = true
        var levelName: String = "floating"
        var fps: Int = 30
        var autoFollow: Bool = true
        var autoReconnect: Bool = true
        var showFloating: Bool = true
        var launchAtLogin: Bool = false
        var cropByApp: [String: [Double]]? = nil

        init() {}

        /// 手写解码：**每个字段都允许缺失**。
        /// 用合成解码器时，即使属性有默认值，缺 key 也会抛错 ——
        /// 一加新字段就会让老配置文件整个解不出来（设置被静默重置），踩过一次。
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            target = try c.decodeIfPresent(TargetSpec.self, forKey: .target)
            cropTop = try c.decodeIfPresent(Double.self, forKey: .cropTop) ?? 0
            cropRight = try c.decodeIfPresent(Double.self, forKey: .cropRight) ?? 0
            cropBottom = try c.decodeIfPresent(Double.self, forKey: .cropBottom) ?? 0
            cropLeft = try c.decodeIfPresent(Double.self, forKey: .cropLeft) ?? 0
            opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
            cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 10
            showBorder = try c.decodeIfPresent(Bool.self, forKey: .showBorder) ?? true
            levelName = try c.decodeIfPresent(String.self, forKey: .levelName) ?? "floating"
            fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? 30
            autoFollow = try c.decodeIfPresent(Bool.self, forKey: .autoFollow) ?? true
            autoReconnect = try c.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? true
            showFloating = try c.decodeIfPresent(Bool.self, forKey: .showFloating) ?? true
            launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
            cropByApp = try c.decodeIfPresent([String: [Double]].self, forKey: .cropByApp)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: "state"),
              let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        target = p.target
        cropTop = p.cropTop; cropRight = p.cropRight
        cropBottom = p.cropBottom; cropLeft = p.cropLeft
        opacity = p.opacity; cornerRadius = p.cornerRadius
        showBorder = p.showBorder
        levelName = p.levelName; fps = p.fps
        autoFollow = p.autoFollow; autoReconnect = p.autoReconnect
        showFloating = p.showFloating; launchAtLogin = p.launchAtLogin
        cropByApp = p.cropByApp ?? [:]
        // 迁移：把当前裁切值记到当前目标 App 名下
        if let b = p.target?.bundleID, cropByApp[b] == nil {
            cropByApp[b] = [p.cropTop, p.cropRight, p.cropBottom, p.cropLeft]
        }
    }

    private func save() {
        guard !isLoading else { return }
        var p = Persisted()
        p.target = target
        p.cropTop = cropTop; p.cropRight = cropRight
        p.cropBottom = cropBottom; p.cropLeft = cropLeft
        p.opacity = opacity; p.cornerRadius = cornerRadius
        p.showBorder = showBorder
        p.levelName = levelName; p.fps = fps
        p.autoFollow = autoFollow; p.autoReconnect = autoReconnect
        p.showFloating = showFloating; p.launchAtLogin = launchAtLogin
        p.cropByApp = cropByApp
        if let d = try? JSONEncoder().encode(p) {
            UserDefaults.standard.set(d, forKey: "state")
        }
    }
}

// MARK: - 开机自启

import ServiceManagement

enum LaunchAtLogin {
    static func register() throws {
        if SMAppService.mainApp.status == .enabled { return }
        try SMAppService.mainApp.register()
    }
    static func unregister() throws {
        if SMAppService.mainApp.status != .enabled { return }
        try SMAppService.mainApp.unregister()
    }
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }
}
