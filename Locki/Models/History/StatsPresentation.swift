//
//  StatsPresentation.swift
//  Locki
//
//  Created by Max Oliinyk on 18.07.2026.
//

import Foundation

nonisolated struct StatsDaySnapshot: Hashable, Sendable {
    let dayStart: Date
    let distanceMeters: Double
    let movingDuration: TimeInterval
    let placeDuration: TimeInterval
    let tripCount: Int
    let visitCount: Int
    let completeness: Double
}

nonisolated struct StatsOverview: Equatable, Sendable {
    let distanceMeters: Double
    let movingDuration: TimeInterval
    let placeDuration: TimeInterval
    let tripCount: Int
    let visitCount: Int
    let trackedDayCount: Int
    let containsIncompleteHistory: Bool

    static let zero = StatsOverview(
        distanceMeters: 0,
        movingDuration: 0,
        placeDuration: 0,
        tripCount: 0,
        visitCount: 0,
        trackedDayCount: 0,
        containsIncompleteHistory: false
    )
}

nonisolated enum StatsChartGranularity: String, Equatable, Sendable {
    case day
    case month
    case year

    var title: String {
        switch self {
        case .day: "Daily Distance"
        case .month: "Monthly Distance"
        case .year: "Yearly Distance"
        }
    }
}

nonisolated struct StatsDistanceBucket: Identifiable, Equatable, Sendable {
    let start: Date
    let distanceMeters: Double
    let completeness: Double

    var id: Date { start }
}

nonisolated enum StatsPresentation {
    static func days(
        _ snapshots: [StatsDaySnapshot],
        in range: DateInterval
    ) -> [StatsDaySnapshot] {
        snapshots
            .filter { $0.dayStart >= range.start && $0.dayStart < range.end }
            .sorted { $0.dayStart < $1.dayStart }
    }

    static func overview(
        days: [StatsDaySnapshot],
        calendar: Calendar = .current
    ) -> StatsOverview {
        guard !days.isEmpty else { return .zero }
        return StatsOverview(
            distanceMeters: days.reduce(0) { $0 + max($1.distanceMeters, 0) },
            movingDuration: days.reduce(0) { $0 + max($1.movingDuration, 0) },
            placeDuration: days.reduce(0) { $0 + max($1.placeDuration, 0) },
            tripCount: days.reduce(0) { $0 + max($1.tripCount, 0) },
            visitCount: days.reduce(0) { $0 + max($1.visitCount, 0) },
            trackedDayCount: Set(days.map { calendar.startOfDay(for: $0.dayStart) }).count,
            containsIncompleteHistory: days.contains { $0.completeness < 1 }
        )
    }

    static func chartGranularity(
        for period: HistoryPeriod,
        range: DateInterval,
        calendar: Calendar = .current
    ) -> StatsChartGranularity? {
        switch period {
        case .day:
            return nil
        case .week, .month:
            return .day
        case .year:
            return .month
        case .all:
            let months = calendar.dateComponents([.month], from: range.start, to: range.end).month ?? 0
            return months > 36 ? .year : .month
        }
    }

    static func distanceBuckets(
        days: [StatsDaySnapshot],
        granularity: StatsChartGranularity,
        calendar: Calendar = .current
    ) -> [StatsDistanceBucket] {
        let grouped = Dictionary(grouping: days) { day in
            switch granularity {
            case .day:
                calendar.startOfDay(for: day.dayStart)
            case .month:
                calendar.dateInterval(of: .month, for: day.dayStart)?.start
                    ?? calendar.startOfDay(for: day.dayStart)
            case .year:
                calendar.dateInterval(of: .year, for: day.dayStart)?.start
                    ?? calendar.startOfDay(for: day.dayStart)
            }
        }

        return grouped.map { start, bucketDays in
            StatsDistanceBucket(
                start: start,
                distanceMeters: bucketDays.reduce(0) { $0 + max($1.distanceMeters, 0) },
                completeness: bucketDays.map(\.completeness).min() ?? 1
            )
        }
        .sorted { $0.start < $1.start }
    }
}
