// 设置面板（SwiftUI）
import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var c: AppController
    let onCrosshair: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !c.granted { permissionBanner }
                targetSection
                cropSection
                windowSection
                perfSection
                systemSection
                footer
            }
            .padding(18)
        }
        .frame(minWidth: 520, minHeight: 560)
        .onAppear { c.syncPermissionState(); c.refreshWindows() }
    }

    // MARK: 目标窗口

    private var permissionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("还没有「屏幕录制」权限").font(.system(size: 12, weight: .semibold))
                Text("没有它无法抓取窗口画面。授权后回到这里即可生效。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("去授权") { c.requestScreenPermission() }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.35)))
    }

    private var targetSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: c.granted ? "rectangle.on.rectangle" : "exclamationmark.triangle.fill")
                        .foregroundStyle(c.granted ? Color.secondary : Color.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.target?.displayName ?? "未选择窗口")
                            .font(.system(size: 13, weight: .semibold))
                        Text(c.sourceSizeText.isEmpty ? c.statusText : "\(c.statusText) · 源窗口 \(c.sourceSizeText) 点")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                HStack(spacing: 8) {
                    Button {
                        onCrosshair()
                    } label: {
                        Label("点击窗口选择", systemImage: "scope")
                    }
                    Button {
                        c.showWindowList.toggle()
                        if c.showWindowList { c.refreshWindows() }
                    } label: {
                        Label("从列表选择", systemImage: "list.bullet")
                    }
                    Button {
                        c.refreshWindows()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("重新扫描窗口")
                }

                if c.showWindowList { windowList }

                Toggle("自动跟随源窗口尺寸 / 比例（横竖屏切换）", isOn: $c.autoFollow)
                Toggle("源窗口中断或消失时自动重连", isOn: $c.autoReconnect)
            }
            .padding(6)
        } label: {
            Label("目标窗口", systemImage: "target").font(.headline)
        }
    }

    private var windowList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(c.windows) { w in
                    Button {
                        c.pick(w)
                        c.showWindowList = false
                    } label: {
                        HStack(spacing: 8) {
                            Image(nsImage: Self.icon(for: w.bundleID))
                                .resizable().frame(width: 18, height: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(w.title.isEmpty ? w.appName : w.title)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                Text("\(w.appName) · \(w.sizeText)")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if c.target?.windowID == w.id {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 3).padding(.horizontal, 6)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        }
        .frame(height: 170)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
    }

    // MARK: 裁切

    private var cropSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("窗口抓到的画面包含标题栏/工具栏，用这里的数值把它切掉（单位：点）")
                    .font(.system(size: 11)).foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    numField("上", $c.cropTop)
                    numField("右", $c.cropRight)
                    numField("下", $c.cropBottom)
                    numField("左", $c.cropLeft)
                    Spacer()
                    Button {
                        c.autoCropChrome()
                    } label: {
                        Label("自动识别标题栏", systemImage: "wand.and.stars")
                    }
                    .help(c.axGranted ? "用关闭按钮位置反推标题栏高度"
                                     : "需要「辅助功能」权限（会弹窗请求）")
                }

                HStack(alignment: .top, spacing: 8) {
                    Button("清零") {
                        c.cropTop = 0; c.cropRight = 0; c.cropBottom = 0; c.cropLeft = 0
                    }
                    Text("预览（实时，就是浮窗里显示的画面）")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }

                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(Color.black)
                    if let img = c.preview {
                        Image(decorative: img, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(2)
                    } else {
                        Text("画面未连接").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .frame(height: 190)
            }
            .padding(6)
        } label: {
            Label("画面裁切", systemImage: "crop").font(.headline)
        }
    }

    private func numField(_ label: String, _ value: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("", value: value, format: .number.precision(.fractionLength(0)))
                .frame(width: 52)
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: 浮窗

    private var windowSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("不透明度").font(.system(size: 12)).frame(width: 62, alignment: .leading)
                    Slider(value: $c.opacity, in: 0.15...1)
                    Text(String(format: "%.2f", c.opacity)).font(.system(size: 11, design: .monospaced))
                        .frame(width: 34, alignment: .trailing)
                }
                HStack {
                    Text("圆角").font(.system(size: 12)).frame(width: 62, alignment: .leading)
                    Slider(value: $c.cornerRadius, in: 0...40)
                    Text("\(Int(c.cornerRadius))").font(.system(size: 11, design: .monospaced))
                        .frame(width: 34, alignment: .trailing)
                }
                HStack {
                    Text("层级").font(.system(size: 12)).frame(width: 62, alignment: .leading)
                    Picker("", selection: $c.levelName) {
                        Text("floating（普通浮窗）").tag("floating")
                        Text("status（更高）").tag("status")
                        Text("modal（面板）").tag("modal")
                        Text("screensaver（几乎最高）").tag("screensaver")
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    Spacer()
                }
                HStack(spacing: 16) {
                    Toggle("显示浮窗", isOn: $c.showFloating)
                    Toggle("显示边框", isOn: $c.showBorder)
                    Spacer()
                    Button {
                        c.resetFrame()
                    } label: {
                        Label("重置位置", systemImage: "arrow.uturn.backward")
                    }
                }
                Text("拖动画面 = 移动浮窗；拖四边/四角 = 缩放（比例自动锁定，画面不会被裁掉）")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text("点击浮窗不会有任何副作用：不会穿透到下面的窗口，也不会激活源窗口")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(6)
        } label: {
            Label("浮窗", systemImage: "macwindow.on.rectangle").font(.headline)
        }
    }

    // MARK: 性能

    private var perfSection: some View {
        GroupBox {
            HStack {
                Text("帧率").font(.system(size: 12))
                Picker("", selection: $c.fps) {
                    Text("15（省电）").tag(15)
                    Text("24").tag(24)
                    Text("30（推荐）").tag(30)
                    Text("60").tag(60)
                }
                .labelsHidden().frame(width: 150)
                Spacer()
                Text("看剧 30 足够；静态内容 15 就够")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(6)
        } label: {
            Label("性能", systemImage: "speedometer").font(.headline)
        }
    }

    // MARK: 系统

    private var systemSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                permissionRow(title: "屏幕录制（必需）", ok: c.granted) {
                    Button("授权 / 打开系统设置") { c.requestScreenPermission() }
                }
                permissionRow(title: "辅助功能（可选，仅用于自动识别标题栏）", ok: c.axGranted) {
                    Button("授权") { _ = AX.requestTrust() ; c.syncPermissionState() }
                }
                Toggle("开机自动启动", isOn: $c.launchAtLogin)
                Text("注意：从 /Applications 运行才能设置开机自启")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(6)
        } label: {
            Label("系统", systemImage: "gearshape").font(.headline)
        }
    }

    private func permissionRow(title: String, ok: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? Color.green : Color.orange)
            Text(title).font(.system(size: 12))
            Spacer()
            if !ok { Button("授权", action: action) }
        }
    }

    private var footer: some View {
        HStack {
            Text(c.statusText).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button("退出 PinBox") { NSApp.terminate(nil) }
        }
    }

    static func icon(for bundleID: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
    }
}
