import SwiftUI
import SwiftData
import Charts

struct ListeningStatisticsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ListeningSession.date, order: .forward) private var sessions: [ListeningSession]
    
    @State private var selectedTimeframe: StatsTimeframe = .week
    @State private var showResetAlert = false
    @State private var referenceDate = Date()
    private var range: StatisticsRange { selectedTimeframe.range(now: referenceDate) }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                summaryCard
                
                Picker("Timeframe", selection: $selectedTimeframe) {
                    ForEach(StatsTimeframe.allCases) { timeframe in
                        Text(timeframe.rawValue).tag(timeframe).accessibilityLabel(timeframe.title)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                
                timeChart
                wordsChart
                lifetimeTotals
                
                Button(role: .destructive, action: {
                    showResetAlert = true
                }) {
                    Text("Reset Statistics")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(uiColor: .secondarySystemGroupedBackground))
                        .cornerRadius(12)
                }
                .padding(.horizontal)
                .padding(.top, 16)
            }
            .padding(.vertical)
        }
        .onAppear { referenceDate = Date() }
        .navigationTitle("Listening Stats")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Reset Statistics?", isPresented: $showResetAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                resetStatistics()
            }
        } message: {
            Text("This will permanently delete your entire listening history and lifetime totals. This cannot be undone.")
        }
    }
    
    private func resetStatistics() {
        for session in sessions {
            modelContext.delete(session)
        }
        try? modelContext.save()
    }
    
    // MARK: - Summary Card
    private var summaryCard: some View {
        let (total, average) = calculateRecentSummary()
        
        return VStack(spacing: 8) {
            Text(selectedTimeframe.title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            Text("\(range.start.formatted(date: .abbreviated, time: .omitted)) – \(range.end.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption).foregroundStyle(.secondary)
            Text(formatDuration(total))
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .tracking(-1)
            
            Text("\(formatDuration(average)) / day average")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .cornerRadius(16)
        .padding(.horizontal)
    }
    
    // MARK: - Charts
    private var timeChart: some View {
        VStack(alignment: .leading) {
            Text("Time Listened · \(formatDuration(calculateRecentSummary().total))")
                .font(.headline)
                .padding(.horizontal)
            
            Chart {
                let data = aggregateData(by: selectedTimeframe, value: \.secondsListened)
                ForEach(data, id: \.date) { item in
                    BarMark(
                        x: .value("Date", item.date, unit: unit(for: selectedTimeframe)),
                        y: .value("Minutes", item.value / 60.0)
                    )
                    .foregroundStyle(DesignSystem.accent.gradient)
                    .cornerRadius(8)
                    .accessibilityLabel(item.date.formatted(date: .abbreviated, time: .omitted))
                    .accessibilityValue(formatDuration(item.value))
                }
            }
            .chartXScale(domain: range.chartDomain())
            .frame(height: 200)
            .padding(.horizontal)
        }
    }
    
    private var wordsChart: some View {
        VStack(alignment: .leading) {
            Text("Words Listened")
                .font(.headline)
                .padding(.horizontal)
            
            Chart {
                let data = aggregateData(by: selectedTimeframe, value: \.wordsListened)
                ForEach(data, id: \.date) { item in
                    BarMark(
                        x: .value("Date", item.date, unit: unit(for: selectedTimeframe)),
                        y: .value("Words", item.value)
                    )
                    .foregroundStyle(Color.orange.gradient)
                    .cornerRadius(8)
                    .accessibilityLabel(item.date.formatted(date: .abbreviated, time: .omitted))
                    .accessibilityValue("\(Int(item.value)) words")
                }
            }
            .chartXScale(domain: range.chartDomain())
            .frame(height: 200)
            .padding(.horizontal)
        }
    }
    
    // MARK: - Lifetime Totals
    private var lifetimeTotals: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Lifetime Totals")
                .font(.headline)
            
            let totalTime = sessions.reduce(0) { $0 + $1.secondsListened }
            let totalWords = sessions.reduce(0) { $0 + Double($1.wordsListened) }
            
            let measured = sessions.filter { $0.measurementVersion == 2 }
            let measuredTime = measured.reduce(0) { $0 + $1.secondsListened }
            let measuredWords = measured.reduce(0) { $0 + $1.wordsListened }
            let wpm = ListeningMetrics.wpm(words: measuredWords, seconds: measuredTime)
            let distinctChapters = Set(sessions.map { $0.documentId }).count

            VStack(spacing: 0) {
                statRow(title: "Time Listened", value: formatDuration(totalTime))
                Divider().padding(.leading)
                statRow(title: "Words Listened", value: formatNumber(Int(totalWords)))
                Divider().padding(.leading)
                statRow(title: "Average Listening WPM", value: wpm.map { String(format: "%.0f WPM", $0) } ?? "—")
                Divider().padding(.leading)
                statRow(title: "Chapters Listened", value: "\(distinctChapters)")
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .cornerRadius(12)
        }
        .padding(.horizontal)
    }
    
    private func statRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
    
    // MARK: - Helpers
    private func calculateRecentSummary() -> (total: Double, average: Double) {
        let total = sessions.filter { range.contains($0.date) }.reduce(0) { $0 + $1.secondsListened }
        return (total, total / Double(range.days))
    }

    private func unit(for timeframe: StatsTimeframe) -> Calendar.Component { timeframe.bucket }
    struct AggregatedData { let date: Date; let value: Double }

    private func aggregateData(by timeframe: StatsTimeframe, value keyPath: KeyPath<ListeningSession, Double>) -> [AggregatedData] {
        aggregateData { $0[keyPath: keyPath] }
    }
    private func aggregateData(by timeframe: StatsTimeframe, value keyPath: KeyPath<ListeningSession, Int>) -> [AggregatedData] {
        aggregateData { Double($0[keyPath: keyPath]) }
    }
    private func aggregateData(value: (ListeningSession) -> Double) -> [AggregatedData] {
        let calendar = Calendar.current
        var grouped: [Date: Double] = [:]
        for session in sessions where range.contains(session.date) {
            let date = calendar.dateInterval(of: range.bucket, for: session.date)?.start ?? session.date
            grouped[date, default: 0] += value(session)
        }
        return range.bucketDates(calendar: calendar).map { AggregatedData(date: $0, value: grouped[$0] ?? 0) }
    }
    private func formatDuration(_ seconds: Double) -> String { ListeningDurationFormat.string(seconds) }

    private func formatNumber(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }
}
