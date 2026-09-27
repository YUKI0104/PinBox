// 十字准星选窗口：全屏半透明遮罩 + 高亮鼠标下的窗口
import AppKit

@MainActor
final class PickerOverlay {

    private var panels: [(window: PanelWindow, view: PickerView)] = []
    private var candidates: [WindowInfo] = []
    private var onPick: ((WindowInfo) -> Void)?
    private var onCancel: (() -> Void)?
    private var hovered: WindowInfo?

    var isActive: Bool { !panels.isEmpty }

    func begin(candidates: [WindowInfo],
               onPick: @escaping (WindowInfo) -> Void,
               onCancel: @escaping () -> Void) {
        end()
        self.candidates = candidates
        self.onPick = onPick
        self.onCancel = onCancel
        self.hovered = nil

        let mainH = NSScreen.screens.first?.frame.height ?? 0
        for screen in NSScreen.screens {
            let win = PanelWindow(contentRect: screen.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)
            win.backgroundColor = .clear
            win.isOpaque = false
            win.hasShadow = false
            win.ignoresMouseEvents = false
            win.acceptsMouseMovedEvents = true
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let v = PickerView(frame: NSRect(origin: .zero, size: screen.frame.size))
            v.screenOrigin = screen.frame.origin
            v.mainScreenHeight = mainH
            v.overlay = self
            win.contentView = v
            win.makeKeyAndOrderFront(nil)
            panels.append((win, v))
        }
        NSApp.activate(ignoringOtherApps: true)
        panels.first?.window.makeKey()
    }

    func end() {
        for p in panels { p.window.orderOut(nil); p.window.contentView = nil }
        panels.removeAll()
        onPick = nil
        onCancel = nil
        hovered = nil
    }

    fileprivate func updateHover(at screenPoint: NSPoint, mainScreenHeight: CGFloat) {
        // NS 全局坐标 → CG 全局坐标（y 翻转）后取该点最靠前的窗口
        let cg = CGPoint(x: screenPoint.x, y: mainScreenHeight - screenPoint.y)
        guard let win = WindowCatalog.window(at: cg, in: candidates), win.id != hovered?.id else { return }
        hovered = win
        redraw()
    }

    fileprivate var hoveredWindow: WindowInfo? { hovered }

    private func redraw() { for p in panels { p.view.needsDisplay = true } }

    fileprivate func commit() {
        guard let w = hovered else { cancel(); return }
        let cb = onPick
        end()
        cb?(w)
    }

    fileprivate func cancel() {
        let cb = onCancel
        end()
        cb?()
    }
}

final class PickerView: NSView {
    weak var overlay: PickerOverlay?
    var screenOrigin: NSPoint = .zero
    var mainScreenHeight: CGFloat = 0
    private var tracking: NSTrackingArea?

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseMoved(with event: NSEvent) {
        overlay?.updateHover(at: event.locationInWindow, mainScreenHeight: mainScreenHeight)
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) {}
    override func mouseDown(with event: NSEvent) { overlay?.commit() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { overlay?.cancel() }      // Esc
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.28).cgColor)
        ctx.fill(bounds)

        guard let win = overlay?.hoveredWindow else {
            drawHint(at: NSPoint(x: bounds.midX, y: bounds.midY))
            return
        }
        // CG 全局坐标 → 本视图局部坐标
        var r = win.frame
        r.origin.y = mainScreenHeight - r.maxY
        r.origin.x -= screenOrigin.x
        r.origin.y -= screenOrigin.y
        guard r.intersects(bounds) else { return }
        let local = r.intersection(bounds)

        // 挖空高亮区
        ctx.setBlendMode(.clear)
        ctx.fill(local)
        ctx.setBlendMode(.normal)

        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(2)
        ctx.stroke(local.insetBy(dx: 1, dy: 1))

        // 标签
        let text = "\(win.displayName)  \(win.sizeText)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let pad: CGFloat = 8
        var origin = NSPoint(x: local.minX, y: local.maxY + 8)
        if origin.y + size.height + pad * 2 > bounds.maxY { origin.y = local.maxY - size.height - pad * 2 - 8 }
        if origin.x + size.width + pad * 2 > bounds.maxX { origin.x = bounds.maxX - size.width - pad * 2 }
        let box = NSRect(x: origin.x, y: origin.y, width: size.width + pad * 2, height: size.height + pad * 2)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        (text as NSString).draw(at: NSPoint(x: box.minX + pad, y: box.minY + pad), withAttributes: attrs)
    }

    private func drawHint(at p: NSPoint) {
        let text = "点击要置顶的窗口　·　Esc 取消"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let box = NSRect(x: p.x - size.width / 2 - 12, y: p.y - size.height / 2 - 8,
                         width: size.width + 24, height: size.height + 16)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        (text as NSString).draw(at: NSPoint(x: box.minX + 12, y: box.minY + 8), withAttributes: attrs)
    }
}
