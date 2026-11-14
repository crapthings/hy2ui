import SwiftUI

/// Presents physical-interface traffic trends, FINAL selection and infrequent capture controls.
struct DashboardTrafficView: View {
    @Bindable var model: AppModel
    let wide: Bool
    var openActivity: () -> Void
    @State private var traffic = DashboardNetworkModel()
    @State private var activity = ProcessNetworkModel()
    @State private var device = DashboardDeviceModel()
    @State private var monthlyTraffic = false
    @State private var cumulativeProcesses = false
    @State private var showingDiagnosis = false
    @AppStorage(DiagnosticTargets.key) private var diagnosticTargets = DiagnosticTargets.defaults
    @State private var latency: Double?
    @State private var dnsLatency: Double?
    @State private var routingError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.gridSpacing) {
            if wide {
                GeometryReader { geometry in
                    let column = max(0, (geometry.size.width - 3 * AppTheme.gridSpacing) / 4)
                    HStack(spacing: AppTheme.gridSpacing) {
                        policyCard.frame(width: column * 2 + AppTheme.gridSpacing)
                        rateCard(upload: true).frame(width: column)
                        rateCard(upload: false).frame(width: column)
                    }
                }.frame(height: 280)
            } else {
                policyCard
                HStack(spacing: AppTheme.gridSpacing) {
                    rateCard(upload: true)
                    rateCard(upload: false)
                }
            }
            HStack(spacing: AppTheme.gridSpacing) {
                totalTrafficCard
                DashboardLANCard(model: model, device: device)
                DashboardMemoryCard(device: device, localized: model.localized)
            }
            if wide {
                HStack(spacing: AppTheme.gridSpacing) {
                    activityOverviewCard
                    activityCard
                }
            } else {
                activityOverviewCard
                activityCard
            }
            captureCard
        }.sheet(isPresented: $showingDiagnosis) {
            let context = measurementContext
            NetworkDiagnosisView(model: model) { measured, dns in
                guard measurementContext == context else { return }
                if let measured { latency = measured }
                if let dns { dnsLatency = dns }
            }
        }
            .onChange(of: measurementContext) { _, _ in latency = nil; dnsLatency = nil }
            .task { await traffic.watch() }
            .task { await activity.watch() }
            .task { await device.watch(model: model) }
    }

    private func rateCard(upload: Bool) -> some View {
        DashboardCard(height: 280) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(model.localized(upload ? "上传" : "下载")).font(AppTheme.cardTitle)
                    Spacer()
                    AppIcon(symbol: upload ? .upload : .download, size: 20)
                        .foregroundStyle(upload ? AppTheme.upload : AppTheme.download)
                }
                DashboardValue(value: traffic.available ? TrafficFormatting.rate(upload ? traffic.upload : traffic.download) : "—")
                DashboardTrend(values: upload ? traffic.uploads : traffic.downloads,
                               color: upload ? AppTheme.upload : AppTheme.download)
                    .frame(maxHeight: .infinity)
            }
        }
    }

    private var totalTrafficCard: some View {
        let sent = monthlyTraffic ? traffic.monthSent : traffic.sent
        let received = monthlyTraffic ? traffic.monthReceived : traffic.received
        return DashboardCard(height: 232) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(model.localized("总流量")).font(AppTheme.caption).foregroundStyle(AppTheme.muted)
                    Spacer(minLength: 4)
                    Picker(model.localized("统计范围"), selection: $monthlyTraffic) {
                        Text(model.localized("当前")).tag(false)
                        Text(model.localized("当月")).tag(true)
                    }.pickerStyle(.segmented).labelsHidden().fixedSize().frame(width: 150, alignment: .trailing)
                }
                DashboardValue(value: TrafficFormatting.bytes(sent + received), size: 34)
                Spacer(minLength: 0)
                HStack(alignment: .top) {
                    routingTrafficColumn(title: "直连", alignment: .leading)
                    Spacer(minLength: 12)
                    routingTrafficColumn(title: "代理", alignment: .trailing)
                }
                Capsule().fill(AppTheme.controlSurface).frame(height: 12)
                    .accessibilityHidden(true)

            }
        }.help(model.localized("顶部为物理网卡总量；直连和代理分项尚无核心计数，显示 —，不代表零。当前为本次首页观察，当月为已保存的采样累计。"))
    }

    private func routingTrafficColumn(title: String, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 7) {
            Text(model.localized(title)).foregroundStyle(AppTheme.muted)
            Text(model.localized("上传") + "  —").monospacedDigit()
            Text(model.localized("下载") + "  —").monospacedDigit()
        }.font(AppTheme.caption)
            .help(model.localized("等待核心提供直连与代理分项计数"))
    }

    private var captureCard: some View {
        HStack(spacing: AppTheme.gridSpacing) {
            captureControl(enhanced: false)
            captureControl(enhanced: true)
        }
    }

    private func captureControl(enhanced: Bool) -> some View {
        let enabled = enhanced ? model.enhancedCaptureEnabled : model.systemProxyCaptureEnabled
        let active = enhanced ? model.enhancedModeActive : model.systemProxyActive
        let title = model.localized(enhanced ? "虚拟网卡" : "系统代理")
        return SectionCard {
            HStack(spacing: 14) {
                AppIcon(symbol: enhanced ? .capture : .address, size: 24)
                    .foregroundStyle(enabled ? AppTheme.accent : AppTheme.muted)
                    .frame(width: 44, height: 44)
                    .background(AppTheme.controlSurface, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(AppTheme.cardTitle)
                    Text(enhanced
                        ? model.localized(active ? "运行中" : enabled ? model.serviceTitle : "已关闭")
                        : "HTTP / HTTPS \(model.profile.httpPort) · SOCKS5 \(model.profile.socksPort)")
                        .font(AppTheme.caption).foregroundStyle(AppTheme.muted)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
                Toggle(title, isOn: Binding(
                    get: { enhanced ? model.enhancedCaptureEnabled : model.systemProxyCaptureEnabled },
                    set: { value in Task { await model.setCapture(enhanced: enhanced, enabled: value) } }
                )).labelsHidden().toggleStyle(.switch).controlSize(.regular)
                    .accessibilityLabel(title)
            }
        }.disabled(!model.canChangeCapture)
    }

    private var measurementContext: String {
        "\(model.defaultServer?.id.uuidString ?? "")|\(model.state)|\(model.routing.configuration.requestMode)|\(model.systemProxyActive)|\(model.enhancedModeActive)|\(model.profile.httpPort)|\(diagnosticTargets)"
    }

    private func latencyValue(_ value: Double?) -> String {
        value.map { String(format: "%.0f", $0) } ?? "—"
    }

    private func latencyMetric(title: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(model.localized(title)).font(AppTheme.caption).foregroundStyle(AppTheme.muted).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(latencyValue(value)).font(.system(size: 23, weight: .semibold)).monospacedDigit()
                if value != nil { Text("ms").font(AppTheme.caption).foregroundStyle(AppTheme.muted) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var policyCard: some View {
        DashboardCard(height: 280) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    FinalPolicyPicker(model: model)
                    routingModePicker
                    Spacer()
                    Button(model.localized("诊断")) { showingDiagnosis = true }.buttonStyle(AppActionStyle())
                }
                DashboardValue(value: latencyValue(latency), unit: latency == nil ? nil : "ms", size: 38)
                    .help(model.localized("首个诊断地址的 HTTPS 首字节耗时，包含 DNS、连接、TLS 和目标响应；不是核心 RTT。"))
                Spacer(minLength: 0)
                HStack(spacing: 16) {
                    latencyMetric(title: "网关", value: nil)
                    Divider().frame(height: 42)
                    latencyMetric(title: "DNS", value: dnsLatency)
                    Divider().frame(height: 42)
                    latencyMetric(title: model.defaultServer?.name ?? "服务器", value: nil)
                }.help(model.localized("网关与服务器 RTT 尚未接入；DNS 为当前系统路径的解析阶段耗时，缓存命中也会影响结果。"))
                RoutingChangeNotice(model: model)
                if let routingError {
                    Text(model.localized(routingError)).font(AppTheme.caption).foregroundStyle(AppTheme.warning).lineLimit(1).help(model.localized(routingError))
                }
            }
        }
    }

    private var routingModePicker: some View {
        HStack(spacing: 4) {
            ForEach([RequestRoutingMode.direct, .global, .rules], id: \.self) { mode in
                Button {
                    do { try model.routing.update { $0.requestMode = mode }; routingError = nil }
                    catch { routingError = error.localizedDescription }
                } label: {
                    Text(model.localized(mode.title)).lineLimit(1)
                }
                .buttonStyle(AppActionStyle(primary: model.routing.configuration.requestMode == mode))
                .accessibilityAddTraits(model.routing.configuration.requestMode == mode ? .isSelected : [])
            }
        }
        .background(AppTheme.controlSurface, in: RoundedRectangle(cornerRadius: AppTheme.controlRadius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.localized("请求模式"))
        .disabled(!model.initialized)
    }

    private var currentActiveProcesses: [ProcessNetworkModel.Row] {
        activity.rows.filter { $0.isPresent && $0.uploadRate + $0.downloadRate > 0 }
    }

    private func processCount(_ value: Int) -> String {
        activity.error == nil ? String(value) : "—"
    }

    private func activityCount(title: String, value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(processCount(value)).font(.system(size: 30, weight: .semibold)).monospacedDigit()
                .foregroundStyle(color)
            Text(model.localized(title)).font(AppTheme.caption).foregroundStyle(AppTheme.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var activityOverviewCard: some View {
        DashboardCard(height: 420) {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text(model.localized("活动概览")).font(AppTheme.cardTitle)
                    Spacer()
                    Button(action: openActivity) { AppIcon(symbol: .forward, size: 16) }
                        .buttonStyle(AppIconButtonStyle())
                        .accessibilityLabel(model.localized("查看进程"))
                        .help(model.localized("查看进程"))
                }
                VStack(alignment: .leading, spacing: 8) {
                    DashboardValue(value: processCount(currentActiveProcesses.count), size: 52)
                    Text(model.localized("活跃进程")).font(AppTheme.caption).foregroundStyle(AppTheme.muted)
                }
                Spacer(minLength: 0)
                if let error = activity.error {
                    Text(model.localized(error)).font(AppTheme.caption).foregroundStyle(AppTheme.warning)
                }
                HStack(spacing: 20) {
                    activityCount(title: "上传中的进程", value: currentActiveProcesses.filter { $0.uploadRate > 0 }.count, color: AppTheme.upload)
                    Divider().frame(height: 58)
                    activityCount(title: "下载中的进程", value: currentActiveProcesses.filter { $0.downloadRate > 0 }.count, color: AppTheme.download)
                }
            }
        }.help(model.localized("统计最近一次系统采样中有流量的进程；同一进程可同时上传和下载，不是连接数。"))
    }

    private var activityCard: some View {
        DashboardCard(height: 420) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(model.localized("进程流量排行")).font(AppTheme.cardTitle)
                    Spacer()
                    Button(model.localized("查看全部"), action: openActivity).buttonStyle(.link)
                }
                Picker(model.localized("统计方式"), selection: $cumulativeProcesses) {
                    Text(model.localized("实时速率")).tag(false)
                    Text(model.localized("进程累计")).tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 280)
                let rows = activeRows
                VStack(spacing: 0) {
                    ForEach(0..<5, id: \.self) { index in
                        if index < rows.count {
                            let row = rows[index]
                            DashboardProcessRow(row: row, cumulative: cumulativeProcesses,
                                share: rankingTotal > 0 ? metric(row) / rankingTotal : 0, localized: model.localized)
                        } else {
                            Color.clear.frame(height: 56).accessibilityHidden(true)
                        }
                    }
                }
                .overlay {
                    if let error = activity.error {
                        Text(model.localized(error)).font(AppTheme.caption).foregroundStyle(AppTheme.warning)
                            .multilineTextAlignment(.center).padding()
                    } else if rows.isEmpty {
                        Text(model.localized("暂无网络活动")).foregroundStyle(AppTheme.muted)
                    }
                }
                .transaction { $0.animation = nil }
            }
        }
    }

    private func metric(_ row: ProcessNetworkModel.Row) -> Double {
        cumulativeProcesses ? Double(row.sent) + Double(row.received) : row.uploadRate + row.downloadRate
    }

    private var rankingTotal: Double {
        activity.rows.filter { cumulativeProcesses || $0.isPresent }.reduce(0) { $0 + metric($1) }
    }

    private var activeRows: [ProcessNetworkModel.Row] {
        Array(activity.rows.filter { (cumulativeProcesses || $0.isPresent) && metric($0) > 0 }
            .sorted {
                let left = metric($0), right = metric($1)
                return left == right ? $0.sample.pid < $1.sample.pid : left > right
            }.prefix(5))
    }
}
