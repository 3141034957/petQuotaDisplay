import Charts
import QuotaCore
import SwiftUI

struct QuotaHistoryView: View {
    let source: QuotaProvider
    let readings: [QuotaSnapshot]
    @State private var selectedPeriod: QuotaPeriod
    @State private var hoveredTime: Date?

    init(source: QuotaProvider, readings: [QuotaSnapshot]) {
        self.source = source
        self.readings = readings
        let initial = QuotaWindowPreference.presentationOrder.first { period in
            readings.contains { $0[period] != nil }
        } ?? .weekly
        _selectedPeriod = State(initialValue: initial)
    }

    private var periods: [QuotaPeriod] {
        QuotaPeriod.allCases.filter { period in readings.contains { $0[period] != nil } }
    }

    var body: some View {
        let series = QuotaHistorySeries(readings: readings, period: selectedPeriod)
        let hoveredPoint = hoveredTime.flatMap(series.nearestPoint(to:))
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("额度周期", selection: $selectedPeriod) {
                    ForEach(periods, id: \.self) { period in Text(period.title).tag(period) }
                }
                .pickerStyle(.segmented)
                .onChange(of: selectedPeriod) { _ in hoveredTime = nil }
                Button("复制 CSV") {
                    QuotaClipboard.copy(series.csv(provider: source, period: selectedPeriod))
                }
                .disabled(series.points.isEmpty)
                .help("复制当前周期的采集记录")
            }

            Chart {
                ForEach(series.points) { point in
                    LineMark(x: .value("采集时间", point.time), y: .value("剩余百分比", point.remainingPercent),
                             series: .value("区间", point.segment))
                    PointMark(x: .value("采集时间", point.time), y: .value("剩余百分比", point.remainingPercent))
                        .symbolSize(16)
                }
                if let hoveredPoint {
                    RuleMark(x: .value("所选采集时间", hoveredPoint.time))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    PointMark(x: .value("所选采集时间", hoveredPoint.time),
                              y: .value("所选余量", hoveredPoint.remainingPercent))
                        .symbolSize(45)
                }
            }
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let percent = value.as(Int.self) { Text("\(percent)%") }
                    }
                }
            }
            .chartXAxisLabel("采集时间")
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    let plot = geometry[proxy.plotAreaFrame]
                    Color.clear.contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let position) where plot.contains(position):
                                hoveredTime = proxy.value(atX: position.x - plot.minX, as: Date.self)
                            default:
                                hoveredTime = nil
                            }
                        }
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel("\(selectedPeriod.title)剩余额度趋势")
            .frame(minHeight: 200)

            if let point = hoveredPoint ?? series.points.last {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(point.time.formatted(.dateTime.month().day().hour().minute().second())) · 剩余 \(point.remainingPercent)%")
                        .monospacedDigit()
                    if let reset = point.resetsAt {
                        Text("重置时间 \(reset.formatted(.dateTime.month().day().hour().minute()))")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
            }
        }
        .padding(20)
        .frame(minWidth: 400, minHeight: 320)
    }
}
