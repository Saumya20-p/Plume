import Foundation

enum StatsTimeframe: String, CaseIterable, Identifiable, Sendable {
    case week = "W", month = "M", sixMonths = "6M", year = "Y"
    nonisolated var id: String { rawValue }
    nonisolated var title: String {
        switch self {
        case .week: return "Last 7 Days"
        case .month: return "Last Month"
        case .sixMonths: return "Last 6 Months"
        case .year: return "Last Year"
        }
    }
    nonisolated var bucket: Calendar.Component { self == .week || self == .month ? .day : .month }
    nonisolated func range(now: Date, calendar: Calendar = .current) -> StatisticsRange {
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let component: Calendar.Component = self == .week ? .day : (self == .year ? .year : .month)
        let count = self == .week ? -7 : (self == .sixMonths ? -6 : -1)
        let start = calendar.date(byAdding: component, value: count, to: endOfDay) ?? now
        let days = max(1, calendar.dateComponents([.day], from: start, to: endOfDay).day ?? 1)
        return StatisticsRange(start: start, end: now, days: days, bucket: bucket)
    }
}

struct StatisticsRange: Sendable {
    let start: Date
    let end: Date
    let days: Int
    let bucket: Calendar.Component
    nonisolated func contains(_ date: Date) -> Bool { date >= start && date <= end }
    nonisolated func bucketDates(calendar: Calendar = .current) -> [Date] {
        var dates: [Date] = []
        var date = calendar.dateInterval(of: bucket, for: start)?.start ?? start
        while date <= end {
            dates.append(date)
            guard let next = calendar.date(byAdding: bucket, value: 1, to: date), next > date else { break }
            date = next
        }
        return dates
    }
}

enum ListeningDurationFormat {
    nonisolated static func string(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0 min" }
        if seconds < 60 { return "<1 min" }
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes) min"
    }
}
