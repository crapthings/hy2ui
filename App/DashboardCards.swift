import SwiftUI

/// Aligns dashboard cards to shared row heights while using the same surface as settings and rule cards.
struct DashboardCard<Content: View>: View {
    let height: CGFloat
    var emphasized = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(AppTheme.cardPadding)
            .frame(height: height)
            .modifier(AppCardSurface(emphasized: emphasized))
    }
}

/// Draws an unlabelled recent-sample trend using real values and a quiet baseline when data is absent.
struct DashboardTrend: View {
    let values: [Double]
    let color: Color

    private var samples: [Double] { values.suffix(60).map { $0.isFinite ? max(0, $0) : 0 } }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let points = points(in: size)
            ZStack {
                Path { path in
                    for fraction in [0.25, 0.75] {
                        let y = size.height * fraction
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                    }
                }.stroke(AppTheme.chartGuide.opacity(0.7), style: StrokeStyle(lineWidth: 0.5, dash: [3, 4]))
                if points.count > 1, let first = points.first, let last = points.last {
                    Path { path in
                        path.move(to: CGPoint(x: first.x, y: size.height))
                        path.addLines(points)
                        path.addLine(to: CGPoint(x: last.x, y: size.height))
                        path.closeSubpath()
                    }.fill(LinearGradient(colors: [color.opacity(0.16), color.opacity(0.015)],
                                          startPoint: .top, endPoint: .bottom))
                    Path { $0.addLines(points) }
                        .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                } else {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: size.height - 1))
                        path.addLine(to: CGPoint(x: size.width, y: size.height - 1))
                    }.stroke(AppTheme.chartGuide, lineWidth: 1)
                }
            }
        }.accessibilityHidden(true)
    }

    private func points(in size: CGSize) -> [CGPoint] {
        let samples = samples
        let peak = max(samples.max() ?? 0, 1)
        return samples.enumerated().map { index, value in
            CGPoint(x: size.width * CGFloat(60 - samples.count + index) / 59,
                    y: 3 + max(0, size.height - 6) * (1 - value / peak))
        }
    }
}

/// Presents large live measurements with consistent numeric spacing and readable scaling in narrow cards.
struct DashboardValue: View {
    let value: String
    var unit: String? = nil
    var size: CGFloat = 34
    var unitColor: Color = AppTheme.muted

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            let parts = value.split(separator: " ", maxSplits: 1)
            Text(parts.first.map(String.init) ?? value)
                .font(.system(size: size, weight: .semibold)).monospacedDigit()
            if let suffix = unit ?? (parts.count > 1 ? String(parts[1]) : nil) {
                Text(suffix).font(AppTheme.body).foregroundStyle(unitColor)
            }
        }
        .lineLimit(1).minimumScaleFactor(0.65)
        .accessibilityElement(children: .combine)
    }
}
