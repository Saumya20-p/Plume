import SwiftUI
import SwiftData
import Charts

enum StatsTimeframe: String, CaseIterable, Identifiable {
    case week = "W"
    case month = "M"
    case sixMonths = "6M"
    case year = "Y"
    
    var id: String { self.rawValue }
}

struct ListeningStatisticsView: View {
    @Query(sort: \ListeningSession.date, order: .forward) private var sessions: [ListeningSession]
    
    @State private var selectedTimeframe: StatsTimeframe = .week
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                summaryCard
                
                Picker("Timeframe", selection: $selectedTimeframe) {
                    ForEach(StatsTimeframe.allCases) { timeframe in
                        Text(timeframe.rawValue).tag(timeframe)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                
                timeChart
                wordsChart
                lifetimeTotals
            }
            .padding(.vertical)
        }
        .navigationTitle("Listening Stats")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    // MARK: - Summary Card
    private var summaryCard: some View {
        let (total, average) = calculateRecentSummary()
        
        return VStack(spacing: 8) {
            Text("This \(selectedTimeframe == .week ? "Week" : "Month")")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            Text(formatDuration(total))
                .font(.system(size: 40, weight: .bold, design: .rounded))
            
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
            Text("Time Listened")
                .font(.headline)
                .padding(.horizontal)
            
            Chart {
                let data = aggregateData(by: selectedTimeframe, value: \.secondsListened)
                ForEach(data, id: \.date) { item in
                    BarMark(
                        x: .value("Date", item.date, unit: unit(for: selectedTimeframe)),
                        y: .value("Hours", item.value / 3600.0)
                    )
                    .foregroundStyle(DesignSystem.accent.gradient)
                    .cornerRadius(4)
                }
            }
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
                    .foregroundStyle(Color.blue.gradient)
                    .cornerRadius(4)
                }
            }
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
            
            // Time saved = time listened at 1.0x - actual time listened
            // Or: secondsListened * (playbackSpeed - 1.0)
            let timeSaved = sessions.reduce(0.0) { total, session in
                if session.playbackSpeed > 1.0 {
                    return total + (session.secondsListened * (session.playbackSpeed - 1.0))
                }
                return total
            }
            
            let distinctChapters = Set(sessions.map { $0.documentId }).count
            let avgSpeed = sessions.isEmpty ? 1.0 : (sessions.reduce(0) { $0 + $1.playbackSpeed } / Double(sessions.count))
            
            VStack(spacing: 0) {
                statRow(title: "Time Listened", value: formatDuration(totalTime))
                Divider().padding(.leading)
                statRow(title: "Words Listened", value: formatNumber(Int(totalWords)))
                Divider().padding(.leading)
                statRow(title: "Time Saved", value: formatDuration(timeSaved))
                Divider().padding(.leading)
                statRow(title: "Average Speed", value: String(format: "%.2fx", avgSpeed))
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
        let calendar = Calendar.current
        let now = Date()
        let startDate: Date
        let days: Int
        
        switch selectedTimeframe {
        case .week:
            startDate = calendar.date(byAdding: .day, value: -7, to: now) ?? now
            days = 7
        case .month:
            startDate = calendar.date(byAdding: .month, value: -1, to: now) ?? now
            days = 30
        case .sixMonths:
            startDate = calendar.date(byAdding: .month, value: -6, to: now) ?? now
            days = 180
        case .year:
            startDate = calendar.date(byAdding: .year, value: -1, to: now) ?? now
            days = 365
        }
        
        let recentSessions = sessions.filter { $0.date >= startDate }
        let total = recentSessions.reduce(0) { $0 + $1.secondsListened }
        let average = total / Double(days)
        
        return (total, average)
    }
    
    private func unit(for timeframe: StatsTimeframe) -> Calendar.Component {
        switch timeframe {
        case .week, .month: return .day
        case .sixMonths, .year: return .month
        }
    }
    
    struct AggregatedData {
        let date: Date
        let value: Double
    }
    
    private func aggregateData(by timeframe: StatsTimeframe, value keyPath: KeyPath<ListeningSession, Double>) -> [AggregatedData] {
        let calendar = Calendar.current
        let now = Date()
        let startDate: Date
        
        switch timeframe {
        case .week:
            startDate = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        case .month:
            startDate = calendar.date(byAdding: .month, value: -1, to: now) ?? now
        case .sixMonths:
            startDate = calendar.date(byAdding: .month, value: -6, to: now) ?? now
        case .year:
            startDate = calendar.date(byAdding: .year, value: -1, to: now) ?? now
        }
        
        let relevantSessions = sessions.filter { $0.date >= startDate }
        
        let component: Calendar.Component = (timeframe == .week || timeframe == .month) ? .day : .month
        
        var grouped = [Date: Double]()
        for session in relevantSessions {
            let startOfPeriod = calendar.dateInterval(of: component, for: session.date)?.start ?? session.date
            grouped[startOfPeriod, default: 0] += session[keyPath: keyPath]
        }
        
        // Fill in missing dates with 0
        var result = [AggregatedData]()
        var currentDate = calendar.dateInterval(of: component, for: startDate)?.start ?? startDate
        let endDate = calendar.dateInterval(of: component, for: now)?.start ?? now
        
        while currentDate <= endDate {
            result.append(AggregatedData(date: currentDate, value: grouped[currentDate] ?? 0))
            currentDate = calendar.date(byAdding: component, value: 1, to: currentDate) ?? currentDate
        }
        
        return result
    }
    
    private func aggregateData(by timeframe: StatsTimeframe, value keyPath: KeyPath<ListeningSession, Int>) -> [AggregatedData] {
        let calendar = Calendar.current
        let now = Date()
        let startDate: Date
        
        switch timeframe {
        case .week:
            startDate = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        case .month:
            startDate = calendar.date(byAdding: .month, value: -1, to: now) ?? now
        case .sixMonths:
            startDate = calendar.date(byAdding: .month, value: -6, to: now) ?? now
        case .year:
            startDate = calendar.date(byAdding: .year, value: -1, to: now) ?? now
        }
        
        let relevantSessions = sessions.filter { $0.date >= startDate }
        
        let component: Calendar.Component = (timeframe == .week || timeframe == .month) ? .day : .month
        
        var grouped = [Date: Double]()
        for session in relevantSessions {
            let startOfPeriod = calendar.dateInterval(of: component, for: session.date)?.start ?? session.date
            grouped[startOfPeriod, default: 0] += Double(session[keyPath: keyPath])
        }
        
        var result = [AggregatedData]()
        var currentDate = calendar.dateInterval(of: component, for: startDate)?.start ?? startDate
        let endDate = calendar.dateInterval(of: component, for: now)?.start ?? now
        
        while currentDate <= endDate {
            result.append(AggregatedData(date: currentDate, value: grouped[currentDate] ?? 0))
            currentDate = calendar.date(byAdding: component, value: 1, to: currentDate) ?? currentDate
        }
        
        return result
    }
    
    private func formatDuration(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
    
    private func formatNumber(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }
}
