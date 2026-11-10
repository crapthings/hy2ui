import SwiftUI
import AppKit

/// Presents capture status and concise actions in the window title bar.
struct ConnectionToolbar: View {
    @Bindable var model: AppModel
    private var enhancedAvailable: Bool {
        model.helperInstaller.status == .current || model.profile.enhancedBackend == .networkExtension
    }
    private var canEdit: Bool { !model.editingDisabled && model.hasServer }

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Button(model.localized(model.profile.enhancedModeEnabled ? "关闭增强模式" : "开启增强模式"), systemImage: "power") {
                    setCapture(enhanced: true, enabled: !model.profile.enhancedModeEnabled)
                }
                .disabled(!canEdit || (!enhancedAvailable && !model.profile.enhancedModeEnabled))
                Divider()
                Button(model.localized("设置向导"), systemImage: "sparkles") { model.showEnhancedSetup() }
                    .disabled(!model.initialized || model.isManagingHelper)
                if model.editingDisabled && model.initialized {
                    Divider()
                    Text(model.localized("断开连接后可修改"))
                }
            } label: {
                statusLabel("增强模式", enabled: model.hasServer && model.profile.enhancedModeEnabled,
                            active: model.enhancedModeActive)
            }
            Menu {
                Button(model.localized(model.profile.systemProxyEnabled ? "关闭系统代理" : "开启系统代理"), systemImage: "power") {
                    setCapture(enhanced: false, enabled: !model.profile.systemProxyEnabled)
                }.disabled(!canEdit)
                Divider()
                Button(model.localized("复制终端代理命令"), systemImage: "terminal") { copyShellCommand() }
                    .disabled(!model.initialized || !model.hasServer || !model.profile.systemProxyEnabled)
                if model.editingDisabled && model.initialized {
                    Divider()
                    Text(model.localized("断开连接后可修改"))
                }
            } label: {
                statusLabel("系统代理", enabled: model.hasServer && model.profile.systemProxyEnabled,
                            active: model.systemProxyActive)
            }
        }
        .menuStyle(.button)
        .buttonStyle(CaptureMenuButtonStyle())
        .menuIndicator(.hidden)
        .tint(AppTheme.ink)
        .fixedSize()
    }

    private func statusLabel(_ title: String, enabled: Bool, active: Bool) -> some View {
        let status = active ? "运行中" : (enabled ? "待连接" : "已关闭")
        return HStack(spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 6))
                .foregroundStyle(active ? AppTheme.connected : (enabled ? AppTheme.warning : AppTheme.muted))
            Text(model.localized(title)).font(AppTheme.body)
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AppTheme.muted)
        }
        .foregroundStyle(AppTheme.ink)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.localized(title))
        .accessibilityValue(model.localized(status))
        .help(model.localized(status))
    }

    private func setCapture(enhanced: Bool, enabled: Bool) {
        guard canEdit, !enhanced || !enabled || enhancedAvailable else { return }
        if enhanced { model.profile.enhancedModeEnabled = enabled }
        else { model.profile.systemProxyEnabled = enabled }
        model.save()
    }

    private func copyShellCommand() {
        guard model.hasServer, model.profile.systemProxyEnabled,
              let command = ShellProxyCommand.make(httpPort: model.profile.httpPort, socksPort: model.profile.socksPort) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }
}

/// Gives title-bar menus a neutral badge surface with compact padding and pressed feedback.
private struct CaptureMenuButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(configuration.isPressed ? AppTheme.selection : AppTheme.cloud,
                        in: RoundedRectangle(cornerRadius: AppTheme.controlRadius))
            .contentShape(RoundedRectangle(cornerRadius: AppTheme.controlRadius))
            .opacity(enabled ? 1 : 0.55)
    }
}
