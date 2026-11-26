import Charts
import QuotaCore
import SwiftUI

struct QuotaHistoryView: View {
    private struct Point: Identifiable {
        let time: Date
        let remainingPercent: Int

        var id: Date { time }
    }

    let readings: [QuotaSnapshot]
    @State private var selectedPeriod: QuotaPeriod

    init(readings: [QuotaSnapshot]) {
        self.readings = readings
        let initial = QuotaWindowPreference.presentationOrder.first { period in
            readings.contains { $0[period] != nil }
        } ?? .weekly
        _selectedPeriod = State(initialValue: initial)
    }

    private var periods: [QuotaPeriod] {
        QuotaPeriod.allCases.filter { period in readings.contains { $0[period] != nil } }
    }

    private var points: [Point] {
        readings.compactMap { reading in
            reading[selectedPeriod].map { Point(time: reading.fetchedAt, remainingPercent: $0.remainingPercent) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("额度周期", selection: $selectedPeriod) {
                ForEach(periods, id: \.self) { period in Text(period.title).tag(period) }
            }
            .pickerStyle(.segmented)

            Chart(points) { point in
                LineMark(x: .value("采集时间", point.time), y: .value("剩余百分比", point.remainingPercent))
                PointMark(x: .value("采集时间", point.time), y: .value("剩余百分比", point.remainingPercent))
                    .symbolSize(16)
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
            .accessibilityLabel("\(selectedPeriod.title)剩余额度趋势")
            .frame(minHeight: 200)
        }
        .padding(20)
        .frame(minWidth: 400, minHeight: 280)
    }
}
