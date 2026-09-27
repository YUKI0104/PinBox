// PinBox — 把任意窗口的「画面」镜像成置顶浮窗
//
// 为什么用镜像：macOS 不允许外部程序修改别的 App 的窗口层级
//（SkyLight 私有 API SLSSetWindowLevel 会被静默忽略；目标 App 带 hardened runtime 时也无法注入），
// 所以只能 ScreenCaptureKit 抓画面 + 自己开一个高层级窗口渲染。
//
// 本文件只做入口和设置窗口管理，其余见各文件。
import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    let controller = AppController()
    private let picker = PickerOverlay()
    private var status: StatusItemController?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusItemController(controller: controller, actions: .init(
            openSettings: { [weak self] in self?.openSettings() },
            crosshair: { [weak self] in self?.beginCrosshair() },
            quit: { NSApp.terminate(nil) }
        ))
        Log.write("启动 v1.0  screenRecording=\(ScreenPermission.granted)  accessibility=\(AX.trusted)  bundle=\(Bundle.main.bundleIdentifier ?? "?")")
        controller.start()
        // 只在第一次启动时弹系统授权提示，之后靠设置面板里的指引
        if !ScreenPermission.granted, !UserDefaults.standard.bool(forKey: "didRequestPermission") {
            UserDefaults.standard.set(true, forKey: "didRequestPermission")
            ScreenPermission.request()
        }
        if controller.target == nil { openSettings() }   // 首次启动：直接引导选窗口
        if CommandLine.arguments.contains("--settings") { openSettings() }
        if CommandLine.arguments.contains("--pick") { beginCrosshair() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: 设置窗口

    func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(c: controller) { [weak self] in self?.beginCrosshair() }
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable],
                               backing: .buffered, defer: false)
            win.title = "PinBox 设置"
            win.contentView = NSHostingView(rootView: view)
            win.isReleasedWhenClosed = false
            win.delegate = self
            win.center()
            settingsWindow = win
        }
        controller.engine?.previewEnabled = true
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === settingsWindow {
            controller.engine?.previewEnabled = false
        }
    }

    // MARK: 十字准星选择

    func beginCrosshair() {
        settingsWindow?.orderOut(nil)
        controller.statusText = "点击要置顶的窗口（Esc 取消）"
        Task {
            var list: [WindowInfo] = []
            do { list = try await WindowCatalog.fetch().infos } catch {}

            // 遮罩要给用户看到，采集枚举失败也不影响选择
            picker.begin(candidates: list) { [weak self] info in
                self?.controller.pick(info)
                self?.controller.statusText = "已选择 \(info.displayName)"
                self?.openSettings()
            } onCancel: { [weak self] in
                self?.controller.statusText = "已取消选择"
                self?.openSettings()
            }
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
