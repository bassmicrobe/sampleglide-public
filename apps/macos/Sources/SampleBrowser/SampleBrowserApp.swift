import SwiftUI
import AppKit

@main struct SampleBrowserApp: App {
    @StateObject private var model = BrowserModel()
    var body: some Scene {
        WindowGroup("SampleGlide") {
            BrowserView(model: model)
                .frame(minWidth: 1180, minHeight: 820)
                .preferredColorScheme(.dark)
                .onAppear {
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    model.handleStartup()
                }
        }
        .defaultSize(width: 1536, height: 1020)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("音声ファイルを開く…", action: model.openLocal).keyboardShortcut("o")
            }
            CommandGroup(replacing: .appSettings) {
                Button("試聴設定…") { model.showPlaybackSettings = true }.keyboardShortcut(",")
                Button("共有 API の接続設定…") { model.showSettings = true }
            }
        }
    }
}

struct PlaybackKeyboardView: NSViewRepresentable {
    let action: () -> Void
    final class Coordinator { var monitor: Any? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view] event in
            guard event.keyCode == 49, !event.isARepeat, event.modifierFlags.intersection([.command,.control,.option]).isEmpty else { return event }
            guard let window = view?.window, event.window === window, window.attachedSheet == nil else { return event }
            if event.window?.firstResponder is NSTextView || event.window?.firstResponder is NSTextField || event.window?.firstResponder is FileDragNSView { return event }
            action(); return nil
        }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) } }
}
