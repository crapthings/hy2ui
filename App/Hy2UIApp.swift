import SwiftUI
import AppKit

/// Provides the main window and menu bar entry points for one shared application model.
@main
struct Hy2UIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            ContentView(model: model).environment(\.locale, model.language.locale).onAppear { delegate.model = model }
        }.defaultSize(width: 1080, height: 740)
            .windowStyle(.hiddenTitleBar)
            .windowToolbarStyle(.unified)
        MenuBarExtra("Hy2UI", systemImage: model.state == .connected ? "network.badge.shield.half.filled" : "network") {
            Text(model.localized(model.state.title))
            Text(model.profile.name)
            if model.state == .connected { Text(model.localized(model.activeCaptureDescription)) }
            Divider()
            if model.state == .connecting {
                Button(model.localized("取消连接")) { Task { await model.disconnect() } }
            } else if model.state == .connected || model.needsConnectionCleanup {
                Button(model.needsConnectionCleanup ? model.localized("重试清理") : model.localized("断开连接")) { Task { await model.disconnect() } }
            } else {
                Button(model.localized("连接")) { Task { await model.connect() } }.disabled(!model.canConnect)
            }
            Button(model.localized("显示主窗口")) { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil) }
            Divider()
            Button(model.localized("退出 Hy2UI")) { NSApp.terminate(nil) }
        }.environment(\.locale, model.language.locale)
    }
}

/// Defers application termination until owned connection resources have been released.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var terminationPending = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !model.isManagingHelper else { return .terminateCancel }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        Task {
            await model.disconnect()
            // If restoration failed, keep the UI available so the user can retry.
            let canQuit = model.canQuit
            terminationPending = false
            NSApp.reply(toApplicationShouldTerminate: canQuit)
        }
        return .terminateLater
    }
}
