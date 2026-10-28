import AppKit
import SwiftUI
import Observation

import UlanziKit

@main struct DialStudioApp {
    static func main() {
        let app = NSApplication.shared
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            app.applicationIconImage = icon
        }
        let delegate = StudioDelegate(); app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
final class StudioDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var model: StudioModel!
    private var item: NSStatusItem!
    private var hud: NSPanel?
    private var hudGeneration = 0
    private let configurationUndo = UndoManager()
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        func arg(_ key: String) -> String? { guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }; return args[i + 1] }
        let render = arg("--render")
        let preview = render != nil || args.contains("--preview")
        model = StudioModel(url: arg("--config").map { URL(fileURLWithPath: $0) } ?? StudioConfiguration.fileURL, demonstration: preview)
        model.onLayerChange = { [weak self] in self?.showHUD($0) }
        model.onMenuBarModeChange = { enabled in NSApp.setActivationPolicy(enabled ? .accessory : .regular) }
        NSApp.setActivationPolicy(model.configuration.menuBarOnly ? .accessory : .regular)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        if render != nil, let appearance = arg("--render-appearance") {
            if appearance == "dark" { window.appearance = NSAppearance(named: .darkAqua) }
            if appearance == "light" { window.appearance = NSAppearance(named: .aqua) }
        }
        // The delegate keeps and reopens this window after its close button is
        // used. AppKit must not release it behind that retained reference.
        window.isReleasedWhenClosed = false
        window.title = "Dial Studio"; window.delegate = self
        model.undoManager = configurationUndo
        let hosting = NSHostingView(rootView: StudioView(model: model))
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = NSRect(x: 0, y: 0, width: 1180, height: 800)
        window.contentView = hosting
        window.setContentSize(NSSize(width: 1180, height: 800))
        window.contentMinSize = NSSize(width: 900, height: 620)
        window.center()
        observeDirty()
        if !preview { window.setFrameAutosaveName("DialStudio.main") }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        createMenus()
        if let render {
            if args.contains("--render-settings") { model.showSettings = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                window.setContentSize(NSSize(width: 1180, height: 800))
                window.setFrame(NSRect(x: 80, y: 80, width: 1180, height: 828), display: true)
                window.layoutIfNeeded()
                let content = (window.attachedSheet ?? window).contentView!
                let view = content.superview ?? content
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: render)) }
                }
                // Rendering never starts the service. Exit directly even if a settings sheet is open.
                exit(0)
            }
        } else if !preview && model.error == nil { model.startService() }
    }
    private func createMenus() {
        let main = NSMenu(); let app = NSMenuItem(); main.addItem(app); let appMenu = NSMenu(); app.submenu = appMenu
        appMenu.addItem(withTitle: L("Dial Studio について"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let settings = appMenu.addItem(withTitle: L("設定…"), action: #selector(showSettings), keyEquivalent: ","); settings.target = self
        appMenu.addItem(.separator()); appMenu.addItem(withTitle: L("Dial Studio を隠す"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: L("終了"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = NSMenuItem(); file.title = L("ファイル"); main.addItem(file); let fileMenu = NSMenu(title: L("ファイル")); file.submenu = fileMenu
        let save = fileMenu.addItem(withTitle: L("保存して反映"), action: #selector(saveConfiguration), keyEquivalent: "s"); save.target = self
        let edit = NSMenuItem(); edit.title = L("編集"); main.addItem(edit); let editMenu = NSMenu(title: L("編集")); edit.submenu = editMenu
        for (title, selector, key) in [(L("取り消す"), "undo:", "z"), (L("切り取り"), "cut:", "x"), (L("コピー"), "copy:", "c"), (L("貼り付け"), "paste:", "v"), (L("すべて選択"), "selectAll:", "a")] { editMenu.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key) }
        NSApp.mainMenu = main
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "dial.high.fill", accessibilityDescription: "Dial Studio")
        let menu = NSMenu()
        let open = menu.addItem(withTitle: L("Dial Studio を開く"), action: #selector(showWindow), keyEquivalent: ""); open.target = self
        let hide = menu.addItem(withTitle: L("ウィンドウを隠す"), action: #selector(hideWindow), keyEquivalent: ""); hide.target = self
        let pause = menu.addItem(withTitle: L("サービスを一時停止 / 再開"), action: #selector(togglePause), keyEquivalent: ""); pause.target = self
        menu.addItem(.separator()); menu.addItem(withTitle: L("終了"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
    }
    @objc private func showWindow() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func hideWindow() { window.orderOut(nil) }
    private func observeDirty() {
        withObservationTracking {
            _ = model.dirty
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.window.isDocumentEdited = self.model.dirty
                self.observeDirty()
            }
        }
    }
    @objc private func togglePause() { model.togglePause() }
    @objc private func showSettings() { model.showSettings = true }
    @objc private func saveConfiguration() { model.save() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { configurationUndo }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.dirty && !model.demonstration {
            let alert = NSAlert(); alert.messageText = L("未保存の変更があります"); alert.informativeText = L("変更を保存してから終了しますか？")
            alert.addButton(withTitle: L("保存して終了")); alert.addButton(withTitle: L("キャンセル")); alert.addButton(withTitle: L("保存せず終了"))
            switch alert.runModal() {
            case .alertFirstButtonReturn: model.save(); if model.dirty { return .terminateCancel }
            case .alertSecondButtonReturn: return .terminateCancel
            default: break
            }
        }
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) { model.stopService() }
    private func showHUD(_ text: String) {
        if hud == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 370, height: 68), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear; panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; hud = panel
        }
        hud?.contentView = NSHostingView(rootView: Text(text).font(.system(size: 15, weight: .medium)).frame(width: 370, height: 68).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)))
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame, width: CGFloat = 370, height: CGFloat = 68, inset: CGFloat = 20
            let position = model.configuration.hudPosition
            let x: CGFloat
            switch position {
            case .topLeft, .bottomLeft: x = frame.minX + inset
            case .topCenter, .bottomCenter: x = frame.midX - width / 2
            case .topRight, .bottomRight: x = frame.maxX - width - inset
            }
            let y: CGFloat
            switch position {
            case .topLeft, .topCenter, .topRight: y = frame.maxY - height - inset
            case .bottomLeft, .bottomCenter, .bottomRight: y = frame.minY + inset
            }
            hud?.setFrameOrigin(NSPoint(x: x, y: y))
        }
        hud?.orderFrontRegardless(); hudGeneration += 1; let token = hudGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in if self?.hudGeneration == token { self?.hud?.orderOut(nil) } }
    }
}
