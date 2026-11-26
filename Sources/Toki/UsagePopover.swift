import Charts
import SwiftUI
import TokiCore

@MainActor
struct UsagePopover: View {
    private enum TrendMetric: String, CaseIterable, Identifiable {
        case tokens, cost, requests
        var id: String { rawValue }
    }

    @Bindable var state: AppState
    let refresh: () -> Void
    let settings: () -> Void
    let quit: () -> Void
    @State private var hoveredSlot: Int?
    @State private var trendMetric: TrendMetric = .tokens

    private let accent = Color(red: 0.35, green: 0.36, blue: 0.80)

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let summary = state.summary {
                        hero(summary)
                        metrics(summary.usage.totals)
                        trend(summary)
                        providers(summary)
                        models(summary)
                    } else {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text(state.local("正在读取本地用量…", "Reading local usage…"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 400)
                    }
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 380, height: 570)
        .tint(accent)
    }

    private var toolbar: some View {
        HStack(spacing: 9) {
            TokiGlyphMark()
                .frame(width: 18, height: 18)
            Text("Toki").font(.system(size: 16, weight: .bold))
            Spacer(minLength: 4)
            Picker(state.local("统计区间", "Time range"), selection: $state.days) {
                ForEach([1, 7, 30], id: \.self) { days in
                    Text(state.windowTitle(days)).tag(days)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 172)
            toolbarButton("arrow.clockwise", state.local("刷新", "Refresh"), action: refresh)
                .disabled(state.refreshing)
            toolbarButton("gearshape", state.local("设置", "Settings"), action: settings)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func toolbarButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .help(title)
        .accessibilityLabel(title)
    }

    private func hero(_ summary: UsageSummary) -> some View {
        let bucket = summary.usage
        let tokens = bucket.totals
        let hit = tokens.input == 0 ? 0 : Double(tokens.cachedInputTokens) / Double(tokens.input)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.local("总 Token", "Total tokens")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(state.compact(summary.totalTokens))
                        .font(.system(size: 37, weight: .semibold, design: .rounded).monospacedDigit())
                        .tracking(-1.5)
                        .contentTransition(.numericText())
                        .help(state.exact(summary.totalTokens))
                        .accessibilityLabel(state.exact(summary.totalTokens))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(state.local("预估费用", "Estimated cost")).font(.caption).foregroundStyle(.secondary)
                    Text(bucket.pricedRecords == 0 ? "—" : state.money(bucket.costUsd))
                        .font(.system(size: 21, weight: .semibold).monospacedDigit())
                        .help(bucket.unpricedRecords > 0 ? state.local("部分请求无价格", "Some requests have no rate") : state.currency.rawValue)
                }
            }
            Divider()
            HStack {
                Label(state.percent(hit), systemImage: "bolt.horizontal.circle")
                    .help(state.local("缓存命中率", "Cache hit rate"))
                    .accessibilityLabel(state.local("缓存命中率", "Cache hit rate") + " " + state.percent(hit))
                Spacer()
                Label("\(state.local("缓存节省", "Cache savings")) \(state.money(bucket.cacheSavingsUsd))",
                      systemImage: "leaf")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(accent)
        }
        .padding(13)
        .background(accent.opacity(0.095), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(accent.opacity(0.17)))
    }

    private func metrics(_ tokens: Tokens) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            metric(state.local("未缓存输入", "Uncached input"), tokens.uncachedInputTokens, symbol: "arrow.up.right")
            metric(state.local("缓存读取", "Cache read"), tokens.cachedInputTokens, symbol: "bolt")
            metric(state.local("缓存写入", "Cache write"), tokens.cacheCreationTokens, symbol: "square.and.arrow.down")
            metric(state.local("输出", "Output"), tokens.outputTokens, symbol: "arrow.down.left",
                   detail: tokens.reasoningTokens > 0
                    ? "\(state.local("推理", "Reasoning")) \(state.compact(tokens.reasoningTokens))" : nil)
        }
    }

    private func metric(_ name: String, _ value: Int64, symbol: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(name, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(state.compact(value)).font(.system(size: 17, weight: .semibold).monospacedDigit())
                    .help(state.exact(value))
                Spacer(minLength: 0)
                if let detail { Text(detail).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
    }

    private struct ChartDatum: Identifiable {
        let slot: Int
        let date: Date
        let provider: Provider
        let tokens: Int64
        let costUsd: Double
        let requests: Int
        var id: String { "\(slot):\(provider.rawValue)" }

        func value(for metric: TrendMetric, currency: Currency, cnyRate: Double) -> Double {
            switch metric {
            case .tokens: Double(tokens)
            case .cost: currency == .usd ? costUsd : costUsd * cnyRate
            case .requests: Double(requests)
            }
        }
    }

    private func trendMetricTitle(_ metric: TrendMetric) -> String {
        switch metric {
        case .tokens: state.local("Token", "Tokens")
        case .cost: state.local("费用", "Cost")
        case .requests: state.local("请求", "Requests")
        }
    }

    private func trend(_ summary: UsageSummary) -> some View {
        let grouped = Dictionary(grouping: summary.trend, by: \.date)
        let dates = grouped.keys.sorted()
        let currency = state.currency
        let cnyRate = state.cnyRate
        let metric = trendMetric
        let slotPoints: [[ChartDatum]] = dates.enumerated().map { position, date in
            (grouped[date] ?? []).map {
                ChartDatum(slot: position, date: date, provider: $0.provider,
                           tokens: $0.tokens, costUsd: $0.costUsd, requests: $0.requests)
            }
        }
        let data = slotPoints.flatMap { $0 }
        let slotTotals: [Double] = slotPoints.map { points in
            points.reduce(0) { $0 + $1.value(for: metric, currency: currency, cnyRate: cnyRate) }
        }
        let ticks = chartTicks(count: dates.count, days: summary.days)
        let yMax = niceChartCeiling(slotTotals.max() ?? 0, metric: metric)
        let yTicks: [Double] = yMax > 0 ? [0, yMax / 2, yMax] : [0]

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                sectionTitle(state.local("用量趋势", "Usage trend"))
                Spacer()
                HStack(spacing: 2) {
                    ForEach(TrendMetric.allCases) { option in
                        let selected = trendMetric == option
                        Button {
                            trendMetric = option
                        } label: {
                            Text(trendMetricTitle(option))
                                .font(.system(size: 10.5, weight: selected ? .semibold : .medium))
                                .foregroundStyle(selected ? .primary : .secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    selected ? AnyShapeStyle(.background) : AnyShapeStyle(.clear),
                                    in: RoundedRectangle(cornerRadius: 5)
                                )
                                .shadow(color: selected ? .black.opacity(0.08) : .clear, radius: 1.5, y: 1)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
            }

            trendChart(data, dates: dates, days: summary.days, metric: metric, yMax: yMax)
            .chartXAxis {
                AxisMarks(values: ticks) { value in
                    if let coordinate = value.as(Double.self), let slot = Int(exactly: coordinate),
                       dates.indices.contains(slot) {
                        AxisValueLabel(anchor: .top) {
                            Text(chartLabel(dates[slot], days: summary.days))
                                .font(.system(size: 9).monospacedDigit())
                                .fixedSize()
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: yTicks) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.75, dash: [2.5, 3]))
                        .foregroundStyle(.secondary.opacity(0.22))
                    if let raw = value.as(Double.self) {
                        AxisValueLabel {
                            Text(formatYAxis(raw, metric: metric))
                                .font(.system(size: 9).monospacedDigit())
                                .fixedSize()
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        Color.clear
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    guard let plotFrame = proxy.plotFrame else { hoveredSlot = nil; return }
                                    let frame = geometry[plotFrame]
                                    let relativeX = location.x - frame.origin.x
                                    guard relativeX >= -4, relativeX <= frame.width + 4,
                                          let raw: Double = proxy.value(atX: relativeX) else {
                                        hoveredSlot = nil
                                        return
                                    }
                                    let slot = Int(raw.rounded())
                                    hoveredSlot = dates.indices.contains(slot) ? slot : nil
                                case .ended:
                                    hoveredSlot = nil
                                }
                            }

                        if let slot = hoveredSlot,
                           dates.indices.contains(slot),
                           let plotFrame = proxy.plotFrame,
                           let barX = proxy.position(forX: Double(slot)) {
                            let frame = geometry[plotFrame]
                            let cardWidth: CGFloat = 196
                            let barCenterX = frame.origin.x + barX
                            let showOnLeft = barCenterX > frame.midX
                            let preferredX = showOnLeft ? (barCenterX - cardWidth - 14) : (barCenterX + 14)
                            let clampedX = min(max(preferredX, 4), max(4, geometry.size.width - cardWidth - 4))

                            hoverTooltipCard(
                                date: dates[slot],
                                days: summary.days,
                                points: slotPoints[slot],
                                metric: metric
                            )
                            .frame(width: cardWidth)
                            .offset(x: clampedX, y: 2)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                        }
                    }
                }
            }
            .padding(.trailing, 10)
            .frame(height: 128)
            .zIndex(10)
        }
        .onChange(of: summary.days) { _, _ in hoveredSlot = nil }
    }

    private func hoverTooltipCard(
        date: Date,
        days: Int,
        points: [ChartDatum],
        metric: TrendMetric
    ) -> some View {
        let currency = state.currency
        let cnyRate = state.cnyRate
        let active = points
            .filter { $0.tokens > 0 || $0.requests > 0 || $0.costUsd > 0 }
            .sorted {
                $0.value(for: metric, currency: currency, cnyRate: cnyRate)
                    > $1.value(for: metric, currency: currency, cnyRate: cnyRate)
            }
        let totalTokens = points.reduce(Int64(0)) { $0 + $1.tokens }
        let totalCostUsd = points.reduce(0.0) { $0 + $1.costUsd }
        let totalRequests = points.reduce(0) { $0 + $1.requests }

        return VStack(alignment: .leading, spacing: 6) {
            Text(tooltipDateTitle(date, days: days))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)

            if active.isEmpty {
                Text(state.local("此时段无用量", "No usage in this bucket"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(active) { entry in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2.5)
                                .fill(entry.provider.tint)
                                .frame(width: 7.5, height: 7.5)
                            Text(entry.provider.name)
                                .font(.system(size: 11))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(formatTooltipValue(entry, metric: metric))
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundStyle(.primary)
                        }
                    }
                }
                Divider()
                HStack(spacing: 6) {
                    Text(state.local("合计", "Total"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(tooltipFooterSummary(tokens: totalTokens, costUsd: totalCostUsd, requests: totalRequests, metric: metric))
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
    }

    private func tooltipDateTitle(_ date: Date, days: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = days == 1 ? "yyyy/MM/dd, HH:00" : "yyyy/MM/dd"
        return formatter.string(from: date)
    }

    private func formatTooltipValue(_ entry: ChartDatum, metric: TrendMetric) -> String {
        switch metric {
        case .tokens:
            return state.compact(entry.tokens)
        case .cost:
            return formatCompactMoney(entry.costUsd)
        case .requests:
            return state.exact(Int64(entry.requests))
        }
    }

    private func tooltipFooterSummary(tokens: Int64, costUsd: Double, requests: Int, metric: TrendMetric) -> String {
        let reqText = state.local("\(requests) 次请求", "\(requests) \(requests == 1 ? "request" : "requests")")
        switch metric {
        case .tokens:
            return "\(state.compact(tokens)) · \(reqText)"
        case .cost:
            return "\(formatCompactMoney(costUsd)) · \(reqText)"
        case .requests:
            return "\(reqText) · \(state.compact(tokens))"
        }
    }

    private func formatCompactMoney(_ dollars: Double) -> String {
        let amount = state.currency == .usd ? dollars : dollars * state.cnyRate
        let prefix = state.currency == .usd ? "$" : "¥"
        if amount > 0 && amount < 0.01 {
            return prefix + amount.formatted(.number.precision(.fractionLength(3)).locale(state.language.locale))
        }
        return prefix + amount.formatted(.number.precision(.fractionLength(2)).locale(state.language.locale))
    }

    private func formatYAxis(_ value: Double, metric: TrendMetric) -> String {
        switch metric {
        case .tokens:
            return state.compact(Int64(value.rounded()))
        case .cost:
            let prefix = state.currency == .usd ? "$" : "¥"
            if value == 0 { return "\(prefix)0" }
            if value < 1 {
                return prefix + value.formatted(.number.precision(.fractionLength(2)).locale(state.language.locale))
            }
            if value < 10 {
                return prefix + value.formatted(.number.precision(.fractionLength(0...1)).locale(state.language.locale))
            }
            return prefix + Int64(value.rounded()).formatted(.number.locale(state.language.locale))
        case .requests:
            return state.compact(Int64(value.rounded()))
        }
    }

    private func trendChart(_ data: [ChartDatum], dates: [Date], days: Int, metric: TrendMetric, yMax: Double) -> some View {
        let barWidth: CGFloat = days == 7 ? 20 : days == 1 ? 8 : 6
        let currency = state.currency
        let cnyRate = state.cnyRate
        return Chart(data) { point in
            let yValue = point.value(for: metric, currency: currency, cnyRate: cnyRate)
            BarMark(
                x: .value("Slot", Double(point.slot)),
                y: .value("Value", yValue),
                width: .fixed(barWidth),
                stacking: .standard
            )
            .foregroundStyle(by: .value("Provider", point.provider.name))
            .cornerRadius(days == 7 ? 3 : 2)
            .opacity(hoveredSlot == nil || hoveredSlot == point.slot ? 1.0 : 0.35)
            .accessibilityLabel(Text(chartLabel(point.date, days: days)))
            .accessibilityValue(Text(formatTooltipValue(point, metric: metric)))
        }
        .chartXScale(domain: -0.6...max(Double(dates.count) - 0.4, 0.6))
        .chartYScale(domain: 0...max(yMax, 1))
        .chartForegroundStyleScale(
            domain: Provider.allCases.map(\.name),
            range: Provider.allCases.map(\.tint)
        )
        .chartLegend(.hidden)
    }

    private func chartTicks(count: Int, days: Int) -> [Double] {
        guard count > 0 else { return [] }
        if days == 7 {
            return Array(stride(from: 0, to: count, by: 2)).map(Double.init)
        }
        if days == 1 {
            return Array(stride(from: 0, to: count, by: 4)).map(Double.init)
        }
        var slots = Array(stride(from: 0, to: count, by: 7))
        if let last = slots.last, count - 1 - last >= 4 {
            slots.append(count - 1)
        }
        return slots.map(Double.init)
    }

    private func niceChartCeiling(_ maxValue: Double, metric: TrendMetric) -> Double {
        guard maxValue > 0 else { return 0 }
        let raw = maxValue * 1.12
        let magnitude = pow(10.0, floor(log10(raw)))
        let normalized = raw / magnitude
        let step: Double
        if normalized <= 1.2 { step = 1.2 }
        else if normalized <= 1.5 { step = 1.5 }
        else if normalized <= 2.0 { step = 2.0 }
        else if normalized <= 2.5 { step = 2.5 }
        else if normalized <= 3.0 { step = 3.0 }
        else if normalized <= 4.0 { step = 4.0 }
        else if normalized <= 5.0 { step = 5.0 }
        else if normalized <= 6.0 { step = 6.0 }
        else if normalized <= 8.0 { step = 8.0 }
        else { step = 10.0 }
        let ceiling = step * magnitude
        return metric == .cost ? ceiling : ceiling.rounded()
    }

    private func chartLabel(_ date: Date, days: Int) -> String {
        if days == 1 {
            let hour = Calendar.current.component(.hour, from: date)
            return String(format: "%02d:00", hour)
        }
        return date.formatted(.dateTime.month(.defaultDigits).day().locale(state.language.locale))
    }

    private func providers(_ summary: UsageSummary) -> some View {
        let rows = summary.providers.filter { $0.usage.totalTokens > 0 }
            .sorted { $0.usage.totalTokens > $1.usage.totalTokens }
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle(state.local("按提供方", "By provider"))
            if rows.isEmpty { empty }
            ForEach(rows) { row in
                let share = summary.totalTokens == 0 ? 0 : Double(row.usage.totalTokens) / Double(summary.totalTokens)
                VStack(spacing: 5) {
                    HStack(spacing: 7) {
                        Circle().fill(row.provider.tint).frame(width: 7, height: 7)
                        Text(row.provider.name).font(.system(size: 12, weight: .medium))
                        Text(state.local("\(row.usage.sessions) 个会话",
                                         "\(row.usage.sessions) \(row.usage.sessions == 1 ? "session" : "sessions")"))
                            .font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text(state.compact(row.usage.totalTokens)).font(.caption.weight(.semibold).monospacedDigit())
                        Text(state.percent(share)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                    ProgressView(value: share).tint(row.provider.tint).accessibilityHidden(true)
                }
                .help(state.exact(row.usage.totalTokens))
            }
        }
    }

    private func models(_ summary: UsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionTitle(state.local("按模型", "By model"))
            if summary.models.isEmpty { empty }
            ForEach(Array(summary.models.prefix(10))) { row in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.model.isEmpty ? state.local("未知模型", "Unknown model") : row.model)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                        Text(row.provider.name).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(state.compact(row.usage.totalTokens)).font(.caption.weight(.semibold).monospacedDigit())
                        Text(row.usage.pricedRecords == 0 ? "—" : state.money(row.usage.costUsd))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 3)
                .help("\(row.model)\n\(state.exact(row.usage.totalTokens)) \(state.local("Token", "tokens"))")
            }
        }
    }

    private var empty: some View {
        Text(state.local("此区间暂无用量", "No usage in this range"))
            .font(.caption).foregroundStyle(.secondary)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let summary = state.summary {
                HStack {
                    Text("\(state.local("更新于", "Updated")) \(state.timestamp(summary.updatedAt))")
                    Spacer()
                    if state.refreshing {
                        ProgressView().controlSize(.mini)
                    } else if summary.partial {
                        let affected = summary.sources
                            .filter { $0.state == .partial }
                            .map(\.provider.name)
                            .joined(separator: ", ")
                        Label(state.local("部分来源异常", "Partial sources"), systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                            .help(state.local(
                                "部分历史文件读取失败或格式异常：\(affected)",
                                "Some local history files could not be read: \(affected)"
                            ))
                    }
                }
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack {
                Button(action: state.copySummary) {
                    Label(state.copied ? state.local("已复制", "Copied") : state.local("复制摘要", "Copy Summary"),
                          systemImage: state.copied ? "checkmark" : "doc.on.doc")
                }
                .disabled(state.summary == nil)
                Spacer()
                Button(state.local("设置", "Settings"), action: settings)
                Button(state.local("退出", "Quit"), action: quit)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }
}

private struct TokiGlyphMark: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 18.0
            context.scaleBy(x: scale, y: scale)

            var arc = Path()
            arc.move(to: CGPoint(x: 3.0, y: 5.0))
            arc.addCurve(
                to: CGPoint(x: 15.0, y: 5.0),
                control1: CGPoint(x: 5.5, y: 2.3),
                control2: CGPoint(x: 12.5, y: 2.3)
            )
            context.stroke(
                arc,
                with: .color(.secondary.opacity(0.65)),
                style: StrokeStyle(lineWidth: 1.4, lineCap: .round)
            )

            let bars: [(CGRect, Double)] = [
                (CGRect(x: 2.6, y: 10.6, width: 3.1, height: 4.6), 0.60),
                (CGRect(x: 7.45, y: 8.4, width: 3.1, height: 6.8), 0.82),
                (CGRect(x: 12.3, y: 6.2, width: 3.1, height: 9.0), 1.00),
            ]
            for (rect, opacity) in bars {
                var layer = context
                layer.opacity = opacity
                layer.fill(
                    Path(roundedRect: rect, cornerRadius: 1.1),
                    with: .linearGradient(
                        Gradient(colors: [
                            Color(red: 0x60 / 255.0, green: 0xa5 / 255.0, blue: 0xfa / 255.0),
                            Color(red: 0x2d / 255.0, green: 0xd4 / 255.0, blue: 0xbf / 255.0),
                            Color(red: 0x4a / 255.0, green: 0xde / 255.0, blue: 0x80 / 255.0),
                        ]),
                        startPoint: CGPoint(x: 2.6, y: 15.2),
                        endPoint: CGPoint(x: 15.4, y: 6.2)
                    )
                )
            }
        }
    }
}
