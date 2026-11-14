import SwiftUI
import Foundation

/// Holds one bounded HTTPS probe's response and timing without retaining response bodies or credentials.
private struct NetworkProbeResult: Sendable {
    let target: String
    let viaProxy: Bool
    let output: String
    let exit: Int32
}

/// Runs fixed-target manual HTTPS probes without changing proxy, resolver or route settings.
struct NetworkDiagnosisView: View {
    @Bindable var model: AppModel
    var onMeasurement: ((Double?, Double?) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @AppStorage(DiagnosticTargets.key) private var targets = DiagnosticTargets.defaults
    @State private var results: [NetworkProbeResult] = []
    @State private var running = false
    @State private var generation: UUID?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(model.localized("网络诊断")).font(AppTheme.dialogTitle)
            Text(model.localized("测试地址可在设置中修改，首个地址用于首页延迟。分别检查当前系统路径，以及运行中的本地 HTTP / HTTPS 代理。"))
                .font(AppTheme.caption).foregroundStyle(AppTheme.muted)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(results.enumerated()), id: \.offset) { _, result in
                        SectionCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(result.target + " · " + model.localized(result.viaProxy ? "本地 HTTP / HTTPS 代理" : "当前系统路径")).font(AppTheme.body)
                                Text(model.localized(result.exit == 0 ? "已收到 HTTP 响应" : "连接未完成"))
                                    .foregroundStyle(result.exit == 0 ? AppTheme.connected : AppTheme.warning)
                                Text(result.output).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            }
                        }
                    }
                    if running { ProgressView().frame(maxWidth: .infinity) }
                    if results.isEmpty && !running {
                        Text(model.localized("点击开始诊断，每项最多等待 8 秒。"))
                            .foregroundStyle(AppTheme.muted).frame(maxWidth: .infinity).padding(.vertical, 30)
                    }
                }
            }.frame(height: 330)
            Text(model.localized("DNS、TCP、TLS、Total 为从请求开始计算的秒数；代理远端 DNS 可能显示 0。HTTP 403 等响应仅证明链路可达，不证明登录或业务正常。"))
                .font(AppTheme.caption).foregroundStyle(AppTheme.muted)
            HStack {
                Spacer()
                Button(model.localized("关闭")) { dismiss() }.buttonStyle(AppActionStyle()).keyboardShortcut(.cancelAction)
                Button(model.localized("开始诊断"), action: run).buttonStyle(AppActionStyle(primary: true)).disabled(running)
            }
        }.padding(AppTheme.pagePadding).frame(width: 650)
            .background(AppTheme.canvas).foregroundStyle(AppTheme.ink)
            .onDisappear { generation = nil; task?.cancel(); task = nil }
    }

    private func run() {
        guard let selectedTargets = try? DiagnosticTargets.parse(targets) else { return }
        let selectedConfiguration = targets
        let token = UUID()
        generation = token; running = true; results = []
        let port = model.systemProxyActive ? model.profile.httpPort : nil
        task = Task { @MainActor in
            let context = model.defaultServer?.id
            let mode = model.routing.configuration.requestMode
            let enhanced = model.enhancedModeActive
            for proxy in [false, true] {
                if proxy && port == nil { continue }
                for target in selectedTargets {
                    guard !Task.isCancelled, generation == token else { return }
                    let result = await Task.detached(priority: .utility) {
                        Self.probe(target: target, port: proxy ? port : nil)
                    }.value
                    guard !Task.isCancelled, generation == token else { return }
                    results.append(result)
                    if target == selectedTargets.first, targets == selectedConfiguration, result.exit == 0,
                       model.defaultServer?.id == context, model.routing.configuration.requestMode == mode,
                       model.enhancedModeActive == enhanced, model.systemProxyActive == (port != nil) {
                        func milliseconds(_ marker: String) -> Double? {
                            guard let suffix = result.output.components(separatedBy: marker).dropFirst().first,
                                  let token = suffix.split(separator: " ").first,
                                  let seconds = Double(token.trimmingCharacters(in: CharacterSet(charactersIn: "s"))), seconds > 0 else { return nil }
                            return seconds * 1000
                        }
                        onMeasurement?((proxy || port == nil) ? milliseconds("TTFB ") : nil,
                            proxy ? nil : milliseconds("DNS "))
                    }
                }
            }
            if generation == token { running = false; task = nil }
        }
    }

    nonisolated private static func probe(target: String, port: Int?) -> NetworkProbeResult {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["--disable", "--globoff", "--silent", "--output", "/dev/null", "--max-time", "8", "--connect-timeout", "4",
            "--write-out", "HTTP %{http_code}  DNS %{time_namelookup}s  TCP %{time_connect}s  TLS %{time_appconnect}s  Total %{time_total}s  TTFB %{time_starttransfer}s",
            "--noproxy", port == nil ? "*" : "", "--proxy", port.map { "http://127.0.0.1:\($0)" } ?? "", target]
        let excluded = Set(["http_proxy", "https_proxy", "all_proxy", "no_proxy"])
        process.environment = ProcessInfo.processInfo.environment.filter { !excluded.contains($0.key.lowercased()) }
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return NetworkProbeResult(target: target, viaProxy: port != nil,
                output: String(decoding: data.prefix(1024), as: UTF8.self), exit: process.terminationStatus)
        } catch {
            return NetworkProbeResult(target: target, viaProxy: port != nil, output: "curl unavailable", exit: -1)
        }
    }
}
