// 采集引擎：ScreenCaptureKit 抓窗口 → 置顶浮窗渲染
import AppKit
import ScreenCaptureKit
import CoreImage
import CoreMedia
import QuartzCore

/// 用 NSPanel + .nonactivatingPanel：点浮窗不会把 PinBox 变成活跃 App。
final class PanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class MirrorView: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    var showBorder = true
    private var tracking: NSTrackingArea?

    override var isOpaque: Bool { true }
    /// 默认值是 !isOpaque，本视图不透明，必须显式打开，否则"拖动画面移动窗口"失效
    override var mouseDownCanMoveWindow: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    /// 关键：默认 false 时，浮窗不是 key window 的话第一下点击只用来激活窗口，
    /// mouseDown 根本不会回调到视图里，转发就会全部失效。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 画面在视图里的实际位置（aspect-fit 后的矩形）——坐标换算要用同一个矩形
    var imageRect: NSRect {
        guard let img = image, img.width > 0, img.height > 0 else { return .zero }
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        let s = min(bounds.width / iw, bounds.height / ih)
        let w = iw * s, h = ih * s
        return NSRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    /// 拖动画面 = 移动浮窗（单击原地不动，点击没有任何副作用）
    override func mouseDown(with e: NSEvent) { window?.performDrag(with: e) }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(bounds)
        if let img = image, img.width > 0, img.height > 0 {
            ctx.interpolationQuality = .medium
            ctx.draw(img, in: imageRect)          // aspect-fit：永不裁切、不变形
        }
        if showBorder {
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(hovered ? 0.42 : 0.13).cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(bounds.insetBy(dx: 0.5, dy: 0.5))
        }
    }
}

final class FrameSink: NSObject, SCStreamOutput {
    weak var view: MirrorView?
    var onFrame: ((CGImage) -> Void)?
    private let ci = CIContext(options: [.useSoftwareRenderer: false])
    private var busy = false

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid else { return }
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = arr.first?[.status] as? Int,
           let st = SCFrameStatus(rawValue: raw), st != .complete { return }
        guard !busy, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        busy = true
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let img = ci.createCGImage(CIImage(cvPixelBuffer: pb), from: CGRect(x: 0, y: 0, width: w, height: h))
        DispatchQueue.main.async { [weak self] in
            if let img { self?.view?.image = img; self?.onFrame?(img) }
            self?.busy = false
        }
    }
}

@MainActor
final class Engine: NSObject, SCStreamDelegate, NSWindowDelegate {

    private unowned let controller: AppController
    private var window: PanelWindow?
    private var view: MirrorView?
    private var stream: SCStream?
    private var sink: FrameSink?
    private var cfg: SCStreamConfiguration?

    private var srcWindowID: UInt32 = 0
    private var srcSize: CGSize = .zero
    private var srcRect: CGRect = .zero
    private var aspect: CGFloat = 0
    private let scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2

    private var timer: Timer?
    private var misses = 0
    private var attempts = 0
    private var nextRetryAt = Date.distantPast
    private var lastCfgSize = CGSize.zero
    private var programmaticResize = false
    private var lastPreviewAt = Date.distantPast
    var previewEnabled = false

    private let defaultBox = CGSize(width: 480, height: 760)

    var currentSourceID: UInt32 { srcWindowID }
    var currentSourceSize: CGSize { srcSize }

    init(controller: AppController) {
        self.controller = controller
        super.init()
    }

    // MARK: 启停

    func start() {
        guard timer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        Task { try? await stream?.stopCapture() }
        window?.orderOut(nil)
    }

    /// 目标窗口变了：重建采集流
    func reloadTarget() {
        attempts = 0
        misses = 0
        nextRetryAt = .distantPast
        Task { await detach() }
        tick()
    }

    func applyVisibility() {
        guard let window else { return }
        if controller.showFloating {
            window.orderFrontRegardless()
            if stream == nil { nextRetryAt = .distantPast; tick() }
        } else {
            window.orderOut(nil)
            Task { await detach() }
        }
    }

    /// 外观/裁切/帧率等设置变了
    func applySettings() {
        guard let window, let view else { return }
        view.showBorder = controller.showBorder
        window.alphaValue = controller.opacity
        window.level = Self.level(controller.levelName)
        view.layer?.cornerRadius = controller.cornerRadius
        if stream == nil { return }
        // 关键：裁切变了必须用新值重算采集区域，否则要等下次重连才生效
        refreshSourceRect(relayoutIfNeeded: true)
        pushConfiguration(force: true)
    }

    /// 根据当前裁切值重算采集区域；比例因此变化时同步浮窗形状
    private func refreshSourceRect(relayoutIfNeeded: Bool) {
        guard srcSize.height > 0 else { return }
        srcRect = contentRect(for: srcSize)
        let a = srcRect.width / max(srcRect.height, 1)
        if relayoutIfNeeded, controller.autoFollow, aspect > 0, abs(a - aspect) / aspect > 0.01 {
            aspect = a
            relayout()
        } else {
            aspect = a
        }
    }

    func resetFrame() {
        UserDefaults.standard.removeObject(forKey: "frame")
        guard let window else { return }
        let rect = defaultFrame()
        programmaticResize = true
        window.setFrame(rect, display: true)
        programmaticResize = false
        view?.frame = NSRect(origin: .zero, size: rect.size)
        saveFrame()
    }

    private static func level(_ name: String) -> NSWindow.Level {
        switch name {
        case "status": return NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)))
        case "modal": return NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.modalPanelWindow)))
        case "screensaver": return NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        default: return .floating
        }
    }

    // MARK: 定时同步

    private func tick() {
        guard controller.showFloating else { return }
        if stream == nil {
            guard Date() >= nextRetryAt else { return }
            nextRetryAt = Date().addingTimeInterval(1.5)
            attempts += 1
            Task { await attach(report: attempts <= 3) }
            return
        }
        syncGeometry()
    }

    private func syncGeometry() {
        guard let window, let c = cfg else { return }
        guard let bounds = Self.bounds(of: srcWindowID), bounds.width > 40, bounds.height > 40 else {
            misses += 1
            if misses > 2, controller.autoReconnect {
                misses = 0
                attempts = 0
                Task { await detach() }
            }
            return
        }
        misses = 0
        let size = bounds.size
        if size != srcSize {
            srcSize = size
            srcRect = contentRect(for: size)
            let a = srcRect.width / max(srcRect.height, 1)
            if controller.autoFollow, aspect > 0, abs(a - aspect) / aspect > 0.01 {
                aspect = a
                relayout()
            } else {
                aspect = a
            }
        }
        pushConfiguration(force: false)
                controller.sourceSizeText = "\(Int(srcSize.width))×\(Int(srcSize.height))"
    }

    private static func bounds(of id: UInt32) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in list where (w[kCGWindowNumber as String] as? UInt32) == id {
            guard let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
            return CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
        }
        return nil
    }

    // MARK: 连接 / 断开

    private func detach() async {
        if let s = stream { try? await s.stopCapture() }
        stream = nil; sink = nil; cfg = nil
        lastCfgSize = .zero
        controller.sourceText = "未连接"
    }

    private func attach(report: Bool) async {
        guard ScreenPermission.granted else {
            controller.statusText = "需要「屏幕录制」权限"
            return
        }
        do {
            let result = try await WindowCatalog.fetch()
            controller.windows = result.infos
            guard let spec = controller.target else {
                controller.statusText = "还没选择要置顶的窗口（设置里点「点击窗口选择」）"
                Log.write("attach: 没有目标")
                return
            }
            Log.write("attach: 扫到 \(result.infos.count) 个窗口，目标=\(spec.displayName) bundle=\(spec.bundleID ?? "-")")
            guard let info = WindowCatalog.match(spec, in: result.infos),
                  let sc = result.handles[info.id] else {
                controller.statusText = "没找到目标窗口：\(spec.displayName)"
                Log.write("attach: 没匹配上目标窗口")
                return
            }
            await connect(to: info, sc: sc)
        } catch {
            controller.statusText = "枚举窗口失败：\(error.localizedDescription)"
            Log.write("attach: 枚举窗口失败 \(error)")
        }
    }

    private func connect(to info: WindowInfo, sc: SCWindow) async {
        srcWindowID = info.id
        srcSize = info.frame.size
        srcRect = contentRect(for: srcSize)
        aspect = srcRect.width / max(srcRect.height, 1)
        ensureWindow()

        let c = SCStreamConfiguration()
        let px = captureSize(for: window?.frame.size ?? defaultBox)
        c.width = Int(px.width)
        c.height = Int(px.height)
        c.sourceRect = srcRect
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(controller.fps))
        c.queueDepth = 3
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.showsCursor = false
        c.scalesToFit = true
        cfg = c
        lastCfgSize = px

        let sk = FrameSink()
        sk.view = view
        sk.onFrame = { [weak self] img in self?.offerPreview(img) }
        let st = SCStream(filter: SCContentFilter(desktopIndependentWindow: sc),
                          configuration: c, delegate: self)
        do {
            try st.addStreamOutput(sk, type: .screen,
                                   sampleHandlerQueue: DispatchQueue(label: "pinbox.frames"))
            try await st.startCapture()
            sink = sk; stream = st
            attempts = 0
            controller.sourceText = info.displayName
            controller.sourceSizeText = "\(Int(info.frame.width))×\(Int(info.frame.height))"
            controller.statusText = "正在置顶 \(info.displayName)"
            Log.write("connected \(info.appName) pid=\(info.pid) frame=\(info.frame) crop=\(controller.cropTop)/\(controller.cropRight)/\(controller.cropBottom)/\(controller.cropLeft)")
            controller.didConnect(info, sourceSize: srcSize)
        } catch {
            controller.statusText = "连接失败：\(error.localizedDescription)"
            Log.write("连接失败：\(error)")
            stream = nil; sink = nil; cfg = nil
        }
    }

    private func offerPreview(_ img: CGImage) {
        guard previewEnabled, Date().timeIntervalSince(lastPreviewAt) > 0.25 else { return }
        lastPreviewAt = Date()
        controller.preview = img
    }

    // MARK: 浮窗

    private func ensureWindow() {
        if let window {
            // 已存在：按当前比例修正尺寸
            let want = fitSize(in: CGSize(width: max(window.frame.width, 120),
                                          height: max(window.frame.height, 90)))
            if abs(want.width - window.frame.width) > 1 || abs(want.height - window.frame.height) > 1 {
                relayout()
            }
            window.orderFrontRegardless()
            return
        }
        let rect = savedFrame() ?? defaultFrame()
        let mv = MirrorView(frame: NSRect(origin: .zero, size: rect.size))
        mv.showBorder = controller.showBorder
        mv.wantsLayer = true
        mv.layer?.cornerRadius = controller.cornerRadius
        mv.layer?.masksToBounds = true
        mv.layer?.backgroundColor = NSColor.black.cgColor

        let win = PanelWindow(contentRect: rect,
                              styleMask: [.borderless, .resizable, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        win.isFloatingPanel = true
        win.level = Self.level(controller.levelName)   // NSPanel 会改层级，显式再设一次
        win.contentView = mv
        win.delegate = self
        win.isOpaque = true
        win.backgroundColor = .black
        win.hasShadow = true
        win.level = Self.level(controller.levelName)
        win.alphaValue = controller.opacity
        win.ignoresMouseEvents = false
        win.isMovableByWindowBackground = true
        win.minSize = NSSize(width: 120, height: 90)
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        Log.write("浮窗已创建 level=\(win.level.rawValue)")
        win.acceptsMouseMovedEvents = true
        win.orderFrontRegardless()
        window = win
        view = mv
        saveFrame()
    }

    private func contentRect(for src: CGSize) -> CGRect {
        let t = max(controller.cropTop, 0), r = max(controller.cropRight, 0)
        let b = max(controller.cropBottom, 0), l = max(controller.cropLeft, 0)
        return CGRect(x: l, y: t,
                      width: max(src.width - l - r, 40),
                      height: max(src.height - t - b, 40))
    }

    /// 按画面比例装进 box
    private func fitSize(in box: CGSize) -> CGSize {
        guard aspect > 0 else { return box }
        var w = box.width, h = w / aspect
        if h > box.height { h = box.height; w = h * aspect }
        return CGSize(width: max(w.rounded(), 120), height: max(h.rounded(), 90))
    }

    private func visibleFrame() -> NSRect {
        (window?.screen ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
    }

    private func defaultFrame() -> NSRect {
        let vis = visibleFrame()
        let size = fitSize(in: defaultBox)
        let m: CGFloat = 12
        return NSRect(x: vis.maxX - m - size.width, y: vis.maxY - m - size.height,
                      width: size.width, height: size.height)
    }

    private func savedFrame() -> NSRect? {
        guard let s = UserDefaults.standard.string(forKey: "frame") else { return nil }
        let n = s.split(separator: " ").compactMap { Double($0) }
        guard n.count == 4, n[2] >= 120, n[3] >= 90 else { return nil }
        let vis = visibleFrame()
        var size = CGSize(width: n[2], height: n[3])
        if controller.autoFollow, aspect > 0 {
            let savedAspect = size.width / size.height
            if abs(savedAspect - aspect) / aspect > 0.02 { size = fitSize(in: size) }
        }
        var x = n[0], y = n[1]
        x = min(max(x, vis.minX), max(vis.maxX - size.width, vis.minX))
        y = min(max(y, vis.minY), max(vis.maxY - size.height, vis.minY))
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func saveFrame() {
        guard let f = window?.frame else { return }
        UserDefaults.standard.set(String(format: "%.0f %.0f %.0f %.0f", f.minX, f.minY, f.width, f.height),
                                  forKey: "frame")
    }

    /// 横竖屏切换：保持面积与左上角
    private func relayout() {
        guard let window else { return }
        let vis = visibleFrame()
        let cur = window.frame
        let area = max(cur.width * cur.height, 120 * 90)
        var w = (area * aspect).squareRoot()
        var h = w / aspect
        if h > vis.height { h = vis.height; w = h * aspect }
        if w > vis.width { w = vis.width; h = w / aspect }
        h = max(h, 90); w = max(w, 120)
        var x = cur.minX, y = cur.maxY - h
        x = min(max(x, vis.minX), max(vis.maxX - w, vis.minX))
        y = min(max(y, vis.minY), max(vis.maxY - h, vis.minY))
        programmaticResize = true
        window.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        programmaticResize = false
        view?.frame = NSRect(origin: .zero, size: CGSize(width: w, height: h))
        saveFrame()
    }

    private func captureSize(for windowSize: CGSize) -> CGSize {
        let nativeW = srcRect.width * scale
        let wantW = max(windowSize.width, 320) * scale
        let f = min(1.0, wantW / max(nativeW, 1))
        let w = max((nativeW * f).rounded(), 160)
        return CGSize(width: w, height: max((w * srcRect.height / max(srcRect.width, 1)).rounded(), 90))
    }

    private func pushConfiguration(force: Bool) {
        guard let c = cfg, let win = window else { return }
        let px = captureSize(for: win.frame.size)
        let changed = abs(px.width - lastCfgSize.width) / max(lastCfgSize.width, 1) > 0.08
        if !force && !changed && c.sourceRect == srcRect { return }
        lastCfgSize = px
        c.width = Int(px.width)
        c.height = Int(px.height)
        c.sourceRect = srcRect
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(controller.fps))
        Task { try? await stream?.updateConfiguration(c) }
    }

    // MARK: 代理

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard !programmaticResize, aspect > 0 else { return frameSize }
        let cur = sender.frame.size
        if abs(frameSize.width - cur.width) >= abs(frameSize.height - cur.height) {
            return NSSize(width: frameSize.width.rounded(), height: (frameSize.width / aspect).rounded())
        }
        return NSSize(width: (frameSize.height * aspect).rounded(), height: frameSize.height.rounded())
    }

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) { saveFrame() }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let msg = error.localizedDescription
        Task { @MainActor in
            guard self.controller.autoReconnect else {
                self.controller.statusText = "采集中断：\(msg)"
                return
            }
            self.controller.statusText = "采集中断，重连中…"
            await self.detach()
            self.attempts = 0
            self.nextRetryAt = .distantPast
        }
    }
}
