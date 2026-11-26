import Charts
import QuotaCore
import SwiftUI
import UniformTypeIdentifiers

private struct QuotaHistoryCSV: FileDocument {
    static let readableContentTypes: [UTType] = [.commaSeparatedText]
    let contents: Data

    init(_ text: String) { contents = Data(text.utf8) }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.contents = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: contents)
    }
}

final class QuotaHistoryWindowModel: ObservableObject {
    let context: QuotaHistoryContext
    @Published var readings: [QuotaSnapshot]

    init(context: QuotaHistoryContext, readings: [QuotaSnapshot]) {
        self.context = context
        self.readings = readings
    }
}

struct QuotaHistoryView: View {
    @ObservedObject var model: QuotaHistoryWindowModel
    @State private var selectedPeriod: QuotaPeriod
    @State private var hoveredTime: Date?
    @State private var pinnedTime: Date?
    @State private var timeRange: QuotaHistorySeries.TimeRange = .all
    @State private var exportDocument: QuotaHistoryCSV?
    @State private var isExporting = false
    @State private var exportError: String?
    @State private var showsExportError = false

    init(model: QuotaHistoryWindowModel) {
        self.model = model
        let initial = QuotaWindowPreference.presentationOrder.first { period in
            model.readings.contains { $0[period] != nil }
        } ?? .weekly
        _selectedPeriod = State(initialValue: initial)
    }

    private var readings: [QuotaSnapshot] { model.readings }

    private func csv(for series: QuotaHistorySeries) -> String {
        series.csv(provider: model.context.provider, period: selectedPeriod, modelID: model.context.modelID)
    }

    private var periods: [QuotaPeriod] {
        QuotaPeriod.allCases.filter { period in readings.contains { $0[period] != nil } }
    }

    var body: some View {
        let series = QuotaHistorySeries(readings: readings, period: selectedPeriod, range: timeRange)
        let pinnedPoint = series.points.first { $0.time == pinnedTime } ?? series.points.last
        let hover = hoveredTime.flatMap(series.nearestPoint(to:))
        let highlightedPoint = hover ?? (pinnedTime == nil ? nil : pinnedPoint)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("额度周期", selection: $selectedPeriod) {
                    ForEach(periods, id: \.self) { period in Text(period.title).tag(period) }
                }
                .pickerStyle(.segmented)
                .onChange(of: selectedPeriod) { _ in clearSelection() }
                Picker("时间范围", selection: $timeRange) {
                    ForEach(QuotaHistorySeries.TimeRange.allCases, id: \.self) { range in
                        Text(range.title).tag(range)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: timeRange) { _ in clearSelection() }
                Menu("导出") {
                    Button("复制 CSV") {
                        QuotaClipboard.copy(csv(for: series))
                    }
                    Button("保存 CSV…") {
                        exportDocument = QuotaHistoryCSV(csv(for: series))
                        isExporting = true
                    }
                }
                .disabled(series.points.isEmpty)
                .help("复制当前周期和时间范围内的采集记录")
            }

            Chart {
                ForEach(series.points) { point in
                    if point.resetChanged {
                        RuleMark(x: .value("首次报告新重置时间", point.time))
                            .foregroundStyle(Color.orange.opacity(0.65))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                    LineMark(x: .value("采集时间", point.time), y: .value("剩余百分比", point.remainingPercent),
                             series: .value("区间", point.segment))
                    PointMark(x: .value("采集时间", point.time), y: .value("剩余百分比", point.remainingPercent))
                        .symbolSize(16)
                }
                if let highlightedPoint {
                    RuleMark(x: .value("所选采集时间", highlightedPoint.time))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    PointMark(x: .value("所选采集时间", highlightedPoint.time),
                              y: .value("所选余量", highlightedPoint.remainingPercent))
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
            .opacity(series.points.isEmpty ? 0 : 1)
            .overlay {
                if series.points.isEmpty {
                    Text("此时间范围内没有该周期的采集记录").foregroundStyle(.secondary)
                }
            }

            if let point = highlightedPoint ?? pinnedPoint {
                details(for: point, in: series)
            }
            if series.points.contains(where: \.resetChanged) {
                Label("虚线表示采集报告中的重置时间发生变化", systemImage: "line.diagonal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(minWidth: 400, minHeight: 320)
        .onChange(of: periods) { choices in
            if !choices.contains(selectedPeriod), let first = choices.first { selectedPeriod = first }
        }
        .fileExporter(isPresented: $isExporting, document: exportDocument, contentType: .commaSeparatedText,
                      defaultFilename: "\(model.context.provider.rawValue)-\(selectedPeriod.rawValue)-quota") { result in
            if case .failure(let error) = result {
                exportError = error.localizedDescription
                showsExportError = true
            }
            exportDocument = nil
        }
        .alert("无法保存额度记录", isPresented: $showsExportError) {
            Button("关闭", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    private func clearSelection() {
        hoveredTime = nil
        pinnedTime = nil
    }

    private func details(for point: QuotaHistorySeries.Point, in series: QuotaHistorySeries) -> some View {
        let previous = series.point(adjacentTo: point.time, offset: -1)
        let next = series.point(adjacentTo: point.time, offset: 1)
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(point.time.formatted(.dateTime.month().day().hour().minute().second())) · 剩余 \(point.remainingPercent)%")
                    .monospacedDigit()
                if let reset = point.resetsAt {
                    Text("重置时间 \(reset.formatted(.dateTime.month().day().hour().minute()))")
                        .foregroundStyle(.secondary)
                }
                if point.resetChanged {
                    Text("此记录报告了新的重置时间").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            Spacer()
            stepButton("前一条采集记录", symbol: "chevron.left", point: previous)
            stepButton("后一条采集记录", symbol: "chevron.right", point: next)
        }
    }

    private func stepButton(_ title: String, symbol: String, point: QuotaHistorySeries.Point?) -> some View {
        Button {
            hoveredTime = nil
            pinnedTime = point?.time
        } label: {
            Image(systemName: symbol)
        }
        .accessibilityLabel(title)
        .help(title)
        .disabled(point == nil)
    }
}
