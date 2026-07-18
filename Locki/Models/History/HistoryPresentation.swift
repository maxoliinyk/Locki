//
//  HistoryPresentation.swift
//  Locki
//
//  Created by Max Oliinyk on 18.07.2026.
//

import Foundation

nonisolated struct HistoryDistanceFormatStyle: FormatStyle, Sendable {
    let locale: Locale

    init(locale: Locale = .current) {
        self.locale = locale
    }

    func format(_ value: Double) -> String {
        let meters = value.isFinite ? max(value, 0) : 0
        if meters < 1_000 {
            return Measurement(value: meters.rounded(), unit: UnitLength.meters).formatted(
                Measurement<UnitLength>.FormatStyle(
                    width: .abbreviated,
                    locale: locale,
                    usage: .asProvided,
                    numberFormatStyle: .number.precision(.fractionLength(0))
                )
            )
        }

        let kilometers = (meters / 100).rounded(.toNearestOrAwayFromZero) / 10
        return Measurement(value: kilometers, unit: UnitLength.kilometers).formatted(
            Measurement<UnitLength>.FormatStyle(
                width: .abbreviated,
                locale: locale,
                usage: .asProvided,
                numberFormatStyle: .number.precision(.fractionLength(0...1))
            )
        )
    }
}

nonisolated struct HistoryDurationFormatStyle: FormatStyle, Sendable {
    let locale: Locale

    init(locale: Locale = .current) {
        self.locale = locale
    }

    func format(_ value: TimeInterval) -> String {
        let seconds = value.isFinite ? max(value, 0) : 0
        let minuteValue = floor(seconds / 60)
        let totalMinutes = minuteValue >= Double(Int.max) ? Int.max : Int(minuteValue)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        var components: [String] = []

        if hours > 0 {
            components.append(format(hours, unit: .hours))
        }
        if minutes > 0 || components.isEmpty {
            components.append(format(minutes, unit: .minutes))
        }
        return components.joined(separator: " ")
    }

    private func format(_ value: Int, unit: UnitDuration) -> String {
        Measurement(value: Double(value), unit: unit).formatted(
            Measurement<UnitDuration>.FormatStyle(
                width: .abbreviated,
                locale: locale,
                usage: .asProvided,
                numberFormatStyle: .number.precision(.fractionLength(0))
            )
        )
    }
}

nonisolated enum HistoryPeriod: String, CaseIterable, Hashable, Identifiable, Sendable {
    case day
    case week
    case month
    case year
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: "Day"
        case .week: "Week"
        case .month: "Month"
        case .year: "Year"
        case .all: "All Time"
        }
    }

    func range(
        containing date: Date,
        earliestDate: Date? = nil,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> HistoryDateRange {
        let anchor = min(date, now)
        let interval: DateInterval? = switch self {
        case .day:
            calendar.dateInterval(of: .day, for: anchor)
        case .week:
            calendar.dateInterval(of: .weekOfYear, for: anchor)
        case .month:
            calendar.dateInterval(of: .month, for: anchor)
        case .year:
            calendar.dateInterval(of: .year, for: anchor)
        case .all:
            nil
        }

        if let interval {
            return HistoryDateRange(period: self, anchor: anchor, interval: interval)
        }

        if self == .all {
            return HistoryDateRange(
                period: self,
                anchor: anchor,
                interval: DateInterval(start: min(earliestDate ?? .distantPast, now), end: now)
            )
        }

        let start = calendar.startOfDay(for: anchor)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? anchor
        return HistoryDateRange(
            period: self,
            anchor: anchor,
            interval: DateInterval(start: min(start, end), end: max(start, end))
        )
    }

    func date(
        byAdvancing date: Date,
        value: Int,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Date {
        guard self != .all, value != 0 else { return min(date, now) }
        guard let candidate = calendar.date(byAdding: calendarComponent, value: value, to: date) else {
            return min(date, now)
        }
        return min(candidate, now)
    }

    func canAdvance(
        from date: Date,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Bool {
        guard self != .all,
              let next = calendar.date(byAdding: calendarComponent, value: 1, to: date) else {
            return false
        }
        return next <= now
    }

    private var calendarComponent: Calendar.Component {
        switch self {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        case .all: .day
        }
    }
}

nonisolated struct HistoryDateRange: Hashable, Sendable {
    let period: HistoryPeriod
    let anchor: Date
    let interval: DateInterval

    func title(locale: Locale = .current) -> String {
        switch period {
        case .day:
            interval.start.formatted(
                .dateTime.weekday(.wide).day().month(.wide).year().locale(locale)
            )
        case .week:
            "\(shortDate(interval.start, locale: locale)) – \(shortDate(inclusiveEnd, locale: locale))"
        case .month:
            interval.start.formatted(.dateTime.month(.wide).year().locale(locale))
        case .year:
            interval.start.formatted(.dateTime.year().locale(locale))
        case .all:
            period.title
        }
    }

    private var inclusiveEnd: Date {
        interval.end > interval.start ? interval.end.addingTimeInterval(-1) : interval.end
    }

    private func shortDate(_ date: Date, locale: Locale) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year().locale(locale))
    }
}

extension Double {
    var formattedDistance: String {
        HistoryDistanceFormatStyle().format(self)
    }

    nonisolated func formattedDistance(locale: Locale) -> String {
        HistoryDistanceFormatStyle(locale: locale).format(self)
    }

    var formattedDuration: String {
        HistoryDurationFormatStyle().format(self)
    }

    nonisolated func formattedDuration(locale: Locale) -> String {
        HistoryDurationFormatStyle(locale: locale).format(self)
    }
}
