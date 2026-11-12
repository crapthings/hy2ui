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
        }.defaultSize(width: 1280, height: 920)
            .windowStyle(.hiddenTitleBar)
            .windowToolbarStyle(.unified)
        MenuBarExtra("Hy2UI", systemImage: model.state == .connected ? "network.badge.shield.half.filled" : "network") {
            Text(model.localized(model.serviceTitle))
            Text(model.finalPolicyTitle)
            if model.state == .connected { Text(model.localized(model.activeCaptureDescription)) }
            Divider()
            Group {
                Toggle(model.localized("增强模式"), isOn: Binding(
                    get: { model.enhancedCaptureEnabled },
                    set: { enabled in Task { await model.setCapture(enhanced: true, enabled: enabled) } }
                )).disabled(!model.canChangeCapture)
                Toggle(model.localized("系统代理"), isOn: Binding(
                    get: { model.systemProxyCaptureEnabled },
                    set: { enabled in Task { await model.setCapture(enhanced: false, enabled: enabled) } }
                )).disabled(!model.canChangeCapture)
                if model.needsConnectionCleanup {
                    Button(model.localized("重试清理")) { Task { await model.disconnect() } }
                } else if model.automaticCaptureEnabled && model.state == .idle {
                    Button(model.localized("重试启动")) { Task { await model.connect() } }.disabled(!model.canConnect)
                }
            }.disabled(model.isSwitchingServer || model.isManagingHelper)
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
        guard !model.isManagingHelper && !model.isSwitchingServer else { return .terminateCancel }
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
