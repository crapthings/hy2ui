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

/// Attempts cleanup and lets the user explicitly exit while preserving unresolved recovery records.
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
            var canQuit = model.canQuit
            if !canQuit {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = model.localized("网络恢复尚未确认")
                alert.informativeText = model.localized("退出仅关闭界面，未恢复的代理或后台可能继续存在。恢复记录会保留，重新打开后可继续处理。")
                alert.addButton(withTitle: model.localized("返回并继续恢复"))
                alert.addButton(withTitle: model.localized("仍然退出"))
                canQuit = alert.runModal() == .alertSecondButtonReturn
            }
            terminationPending = false
            NSApp.reply(toApplicationShouldTerminate: canQuit)
        }
        return .terminateLater
    }
}
