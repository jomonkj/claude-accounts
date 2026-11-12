import SwiftUI
import AppKit
import ClaudeAccountsCore

@main
struct ClaudeAccountsApp: App {
    @StateObject private var store = Store()

    init() {
        let args = CommandLine.arguments
        // Debug renders: --render <png> [dark] | --render-settings <tab> <png> | --render-sync <png> | --render-welcome <page> <png>
        let dark = args.contains("dark")
        if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
            let path = args[i + 1]
            Task { @MainActor in
                let store = Store(startTimer: false); await store.refresh(); await store.refreshLiveUsage()
                await renderSnapshot(MenuView().environmentObject(store), path, dark: dark); exit(0)
            }
        }
        if let i = args.firstIndex(of: "--render-settings"), i + 2 < args.count {
            let tab = args[i + 1], path = args[i + 2]
            Task { @MainActor in
                let store = Store(startTimer: false); await store.refresh(); await store.loadBackups(); await store.refreshLiveUsage()
                // The tab bar (a glass effect) does not draw offscreen in dark mode, so the PNG starts below it.
                await renderSnapshot(SettingsView(tab: tab).environmentObject(store).padding(.top, -24), path, dark: dark); exit(0)
            }
        }
        if let i = args.firstIndex(of: "--render-sync"), i + 1 < args.count {
            let path = args[i + 1]
            Task { @MainActor in
                let store = Store(startTimer: false); await store.refresh()
                let dry = await store.run(["sync", "--dry-run"])
                if let s = store.status, let r = try? JSONDecoder().decode(SyncResult.self, from: Data(dry.output.utf8)) {
                    let p = Store.syncPrompt(s, r)
                    await renderAlert(Dialog.alert(p.title, p.text, ok: "Sync"), path, dark: dark)
                }
                exit(0)
            }
        }
        if let i = args.firstIndex(of: "--render-welcome"), i + 2 < args.count {
            let page = Int(args[i + 1]) ?? 0, path = args[i + 2]
            Task { @MainActor in
                let store = Store(startTimer: false); await store.refresh()
                await renderSnapshot(WelcomeView(page: page).environmentObject(store), path, dark: dark); exit(0)
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(store)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: store.menuBarBadge > 0 ? "exclamationmark.circle.fill" : "person.2.circle")
                if store.menuBarBadge > 0 { Text("\(store.menuBarBadge)") }
                else if !store.menuBarTitle.isEmpty { Text(store.menuBarTitle) }
            }
        }
        .menuBarExtraStyle(.window)
    }
}

/// Offscreen window for debug renders. It acts as the key window, so controls show their accent colors.
final class RenderWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

/// Draws a view to a PNG file (debug renders) and returns.
@MainActor
func renderSnapshot<V: View>(_ view: V, _ path: String, dark: Bool) async {
    let host = NSHostingView(rootView: view.environment(\.controlActiveState, .key)
        .background(Color(nsColor: .windowBackgroundColor)))
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    await writePNG(host, path, dark: dark)
}

/// Draws an alert (as `Dialog.confirm` shows it) to a PNG file.
@MainActor
func renderAlert(_ alert: NSAlert, _ path: String, dark: Bool) async {
    if let icon = Bundle.main.image(forResource: "AppIcon") { alert.icon = icon }
    alert.layout()
    guard let view = alert.window.contentView else { return }
    alert.window.contentView = NSView()
    await writePNG(view, path, dark: dark)
}

/// Puts the view in an offscreen key window, then writes it on the window background color.
@MainActor
func writePNG(_ view: NSView, _ path: String, dark: Bool) async {
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
    let win = RenderWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    NSApp.appearance = appearance  // some AppKit controls (the tab bar) read the app appearance
    win.appearance = appearance
    win.contentView = view
    view.layoutSubtreeIfNeeded()
    try? await Task.sleep(nanoseconds: 600_000_000)
    view.layoutSubtreeIfNeeded()
    // 2x pixels, so the PNG is sharp on Retina screens.
    let size = view.bounds.size
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
    rep.size = size
    // Materials (vibrancy) do not draw offscreen, so fill the background first.
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    appearance.performAsCurrentDrawingAppearance { NSColor.windowBackgroundColor.setFill() }
    NSRect(origin: .zero, size: rep.size).fill()
    NSGraphicsContext.restoreGraphicsState()
    appearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: rep) }
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}
