// 菜单栏图标 + 菜单
import AppKit

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {

    private let controller: AppController
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let actions: Actions

    struct Actions {
        var openSettings: () -> Void
        var crosshair: () -> Void
        var quit: () -> Void
    }

    init(controller: AppController, actions: Actions) {
        self.controller = controller
        self.actions = actions
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "PinBox")
            button.image?.isTemplate = true
            button.toolTip = "PinBox — 窗口置顶"
        }
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let head = NSMenuItem(title: controller.sourceText, action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)

        if !controller.sourceSizeText.isEmpty {
            let s = NSMenuItem(title: "源窗口 \(controller.sourceSizeText) 点", action: nil, keyEquivalent: "")
            s.isEnabled = false
            menu.addItem(s)
        }
        menu.addItem(.separator())

        let pickCross = NSMenuItem(title: "点击窗口选择…", action: #selector(crosshair), keyEquivalent: "")
        pickCross.target = self
        menu.addItem(pickCross)

        let recent = NSMenuItem(title: "最近 / 可选窗口", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        if controller.windows.isEmpty { controller.refreshWindows() }
        for w in controller.windows.prefix(30) {
            let item = NSMenuItem(title: "\(w.appName) — \(w.title.isEmpty ? "(无标题)" : w.title)  \(w.sizeText)",
                                  action: #selector(pickFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = w
            item.image = SettingsView.icon(for: w.bundleID)
            item.image?.size = NSSize(width: 16, height: 16)
            if controller.target?.windowID == w.id { item.state = .on }
            sub.addItem(item)
        }
        if controller.windows.isEmpty {
            let none = NSMenuItem(title: "（没扫描到窗口）", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        }
        recent.submenu = sub
        menu.addItem(recent)

        menu.addItem(.separator())

        let show = NSMenuItem(title: "显示浮窗", action: #selector(toggleShow), keyEquivalent: "")
        show.target = self
        show.state = controller.showFloating ? .on : .off
        menu.addItem(show)

        let reset = NSMenuItem(title: "重置浮窗位置", action: #selector(resetFrame), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 PinBox", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func crosshair() { actions.crosshair() }
    @objc private func openSettings() { actions.openSettings() }
    @objc private func quit() { actions.quit() }

    @objc private func toggleShow() {
        controller.showFloating.toggle()
    }

    @objc private func resetFrame() {
        controller.resetFrame()
    }

    @objc private func pickFromMenu(_ sender: NSMenuItem) {
        guard let w = sender.representedObject as? WindowInfo else { return }
        controller.pick(w)
    }
}
