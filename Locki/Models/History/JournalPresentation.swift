//
//  JournalPresentation.swift
//  Locki
//
//  Created by Max Oliinyk on 18.07.2026.
//

import Foundation

nonisolated struct JournalTimelineDescriptor: Hashable, Sendable {
    let id: String
    let date: Date
    let timeZoneIdentifier: String
}

nonisolated struct JournalDayGroup: Hashable, Identifiable, Sendable {
    let dayStart: Date
    let timeZoneIdentifier: String
    let itemIDs: [String]

    var id: String {
        "\(Int(dayStart.timeIntervalSince1970))|\(timeZoneIdentifier)"
    }

    func title(locale: Locale = .current) -> String {
        var calendar = Calendar.current
        let timeZone = TimeZone(identifier: timeZoneIdentifier) ?? calendar.timeZone
        calendar.timeZone = timeZone

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
        return formatter.string(from: dayStart)
    }
}

nonisolated enum JournalPresentation {
    static func overlaps(
        start: Date,
        end: Date?,
        range: DateInterval,
        now: Date = .now
    ) -> Bool {
        let effectiveEnd = end ?? now
        return start < range.end && effectiveEnd > range.start
    }

    static func dayGroups(
        _ items: [JournalTimelineDescriptor],
        calendar: Calendar = .current
    ) -> [JournalDayGroup] {
        let sortedItems = items.sorted {
            $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date
        }
        let grouped = Dictionary(grouping: sortedItems) { item in
            var itemCalendar = calendar
            let timeZone = TimeZone(identifier: item.timeZoneIdentifier) ?? calendar.timeZone
            itemCalendar.timeZone = timeZone
            return DayKey(
                dayStart: itemCalendar.startOfDay(for: item.date),
                timeZoneIdentifier: timeZone.identifier
            )
        }

        return grouped.map { key, values in
            JournalDayGroup(
                dayStart: key.dayStart,
                timeZoneIdentifier: key.timeZoneIdentifier,
                itemIDs: values.map(\.id)
            )
        }
        .sorted {
            if $0.dayStart != $1.dayStart { return $0.dayStart < $1.dayStart }
            return $0.timeZoneIdentifier < $1.timeZoneIdentifier
        }
    }

    static func reducedRoutes(
        _ routes: [[HistoryPoint]],
        pointLimit: Int
    ) -> [[HistoryPoint]] {
        guard pointLimit >= 2 else { return [] }
        let drawableRoutes = routes.filter { $0.count >= 2 }
        guard !drawableRoutes.isEmpty else { return [] }

        let routeLimit = pointLimit / 2
        let selectedRoutes = sampled(drawableRoutes, limit: routeLimit)
        let pointsPerRoute = max(pointLimit / selectedRoutes.count, 2)
        return selectedRoutes.map { sampled($0, limit: pointsPerRoute) }
    }

    static func sampledIndices(count: Int, limit: Int) -> [Int] {
        guard count > 0, limit > 0 else { return [] }
        guard count > limit else { return Array(0..<count) }
        guard limit > 1 else { return [0] }

        return (0..<limit).map { position in
            let fraction = Double(position) / Double(limit - 1)
            return Int((fraction * Double(count - 1)).rounded())
        }
    }

    private static func sampled<Element>(_ values: [Element], limit: Int) -> [Element] {
        guard limit > 0, !values.isEmpty else { return [] }
        guard values.count > limit else { return values }
        return sampledIndices(count: values.count, limit: limit).map { values[$0] }
    }

    private struct DayKey: Hashable {
        let dayStart: Date
        let timeZoneIdentifier: String
    }
}
