// 窗口枚举（ScreenCaptureKit）与 Accessibility 小工具
import AppKit
import ScreenCaptureKit
import ApplicationServices

struct WindowInfo: Identifiable, Hashable {
    let id: UInt32
    let title: String
    let appName: String
    let bundleID: String
    let pid: pid_t
    let frame: CGRect

    var sizeText: String { "\(Int(frame.width))×\(Int(frame.height))" }
    var displayName: String { title.isEmpty ? appName : "\(appName) — \(title)" }
}

enum WindowCatalog {

    /// 可被捕获的窗口：普通层级、有归属 App、不是本程序自己、尺寸够大
    /// 同时返回 SCWindow 句柄，供建采集流使用
    @MainActor
    static func fetch() async throws -> (infos: [WindowInfo], handles: [UInt32: SCWindow]) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let me = getpid()
        var handles: [UInt32: SCWindow] = [:]
        let infos: [WindowInfo] = content.windows.compactMap { w -> WindowInfo? in
            guard let app = w.owningApplication else { return nil }
            guard w.windowLayer == 0 else { return nil }
            guard w.frame.width >= 120, w.frame.height >= 80 else { return nil }
            guard app.processID != me else { return nil }
            guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
            handles[w.windowID] = w
            return WindowInfo(id: w.windowID,
                              title: w.title ?? "",
                              appName: app.applicationName,
                              bundleID: app.bundleIdentifier,
                              pid: app.processID,
                              frame: w.frame)
        }
        .sorted { a, b in
            if a.appName != b.appName { return a.appName < b.appName }
            return a.frame.width * a.frame.height > b.frame.width * b.frame.height
        }
        return (infos, handles)
    }

    /// 在该坐标下最靠前的可捕获窗口
    @MainActor
    static func window(at point: CGPoint, in list: [WindowInfo]) -> WindowInfo? {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                  kCGNullWindowID) as? [[String: Any]] else { return nil }
        for entry in raw {                                   // 已经是前→后顺序
            guard let wid = entry[kCGWindowNumber as String] as? UInt32 else { continue }
            if let hit = list.first(where: { $0.id == wid }) { return hit }
        }
        return nil
    }

    /// 按之前保存的目标规格挑一个当前存在的窗口
    @MainActor
    static func match(_ spec: TargetSpec, in list: [WindowInfo]) -> WindowInfo? {
        if let id = spec.windowID, let exact = list.first(where: { $0.id == id }) { return exact }
        var cands = list
        if let b = spec.bundleID { cands = cands.filter { $0.bundleID == b } }
        if let t = spec.titleContains, !t.isEmpty {
            let withTitle = cands.filter { $0.title.contains(t) }
            if !withTitle.isEmpty { cands = withTitle }
        }
        return cands.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }
}

// MARK: - Accessibility（用于自动识别标题栏高度，可选）

enum AX {
    static var trusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func requestTrust() -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    }

    private static func attr(_ el: AXUIElement, _ key: String) -> CFTypeRef? {
        var out: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, key as CFString, &out) == .success ? out : nil
    }

    private static func point(_ v: CFTypeRef?) -> CGPoint? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    private static func size(_ v: CFTypeRef?) -> CGSize? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    /// 借关闭按钮的垂直居中位置反推标题栏/工具栏高度：
    /// 高度 ≈ 2 × (关闭按钮中心 y − 窗口顶部 y)。实测 MuMu 得 38（与像素测量一致）、
    /// Finder 52、Otty 32。
    static func chromeHeight(pid: pid_t, matchingTitle title: String, windowSize: CGSize) -> CGFloat? {
        guard trusted else { return nil }
        let appEl = AXUIElementCreateApplication(pid)
        guard let wins = attr(appEl, kAXWindowsAttribute as String) as? [AXUIElement] else { return nil }

        var chosen: AXUIElement? = wins.first
        if !title.isEmpty {
            for w in wins where (attr(w, kAXTitleAttribute as String) as? String) == title { chosen = w; break }
        }
        guard let win = chosen,
              let wp = point(attr(win, kAXPositionAttribute as String)),
              let btn = attr(win, kAXCloseButtonAttribute as String) else { return nil }
        let btnEl = btn as! AXUIElement
        guard let bp = point(attr(btnEl, kAXPositionAttribute as String)),
              let bs = size(attr(btnEl, kAXSizeAttribute as String)) else { return nil }
        let center = bp.y + bs.height / 2
        let h = (center - wp.y) * 2
        guard h > 8, h < windowSize.height / 2 else { return nil }
        return (h).rounded()
    }
}

// MARK: - 屏幕录制权限

enum ScreenPermission {
    static var granted: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func request() -> Bool { CGRequestScreenCaptureAccess() }

    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}
