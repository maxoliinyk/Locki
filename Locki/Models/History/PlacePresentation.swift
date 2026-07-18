//
//  PlacePresentation.swift
//  Locki
//
//  Created by Max Oliinyk on 18.07.2026.
//

import Foundation

nonisolated struct PlaceVisitPresentationSnapshot: Hashable, Sendable {
    let placeID: UUID?
    let arrivalDate: Date
    let departureDate: Date?
    let timeZoneIdentifier: String
    let isExcluded: Bool
}

nonisolated struct PlaceDisplayMetrics: Equatable, Sendable {
    let totalDuration: TimeInterval
    let visitCount: Int
    let distinctDayCount: Int

    static let zero = PlaceDisplayMetrics(totalDuration: 0, visitCount: 0, distinctDayCount: 0)

    var countSummary: String {
        let visitLabel = visitCount == 1 ? "visit" : "visits"
        let dayLabel = distinctDayCount == 1 ? "day" : "days"
        return "\(visitCount.formatted()) \(visitLabel) · \(distinctDayCount.formatted()) \(dayLabel)"
    }
}

nonisolated enum PlacePresentation {
    static func metrics(
        visits: [PlaceVisitPresentationSnapshot],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [UUID: PlaceDisplayMetrics] {
        let validVisits = visits.compactMap { visit -> ValidVisit? in
            guard !visit.isExcluded,
                  let placeID = visit.placeID,
                  visit.arrivalDate <= now else {
                return nil
            }
            let end = min(visit.departureDate ?? now, now)
            guard end >= visit.arrivalDate else { return nil }
            return ValidVisit(placeID: placeID, visit: visit, end: end)
        }

        return Dictionary(grouping: validVisits, by: \.placeID).mapValues { placeVisits in
            let dayKeys = Set(placeVisits.map { validVisit in
                var visitCalendar = calendar
                visitCalendar.timeZone = TimeZone(identifier: validVisit.visit.timeZoneIdentifier)
                    ?? calendar.timeZone
                let components = visitCalendar.dateComponents(
                    [.era, .year, .month, .day],
                    from: validVisit.visit.arrivalDate
                )
                return DayKey(
                    era: components.era ?? 0,
                    year: components.year ?? 0,
                    month: components.month ?? 0,
                    day: components.day ?? 0
                )
            })
            return PlaceDisplayMetrics(
                totalDuration: placeVisits.reduce(0) {
                    $0 + $1.end.timeIntervalSince($1.visit.arrivalDate)
                },
                visitCount: placeVisits.count,
                distinctDayCount: dayKeys.count
            )
        }
    }

    private struct ValidVisit {
        let placeID: UUID
        let visit: PlaceVisitPresentationSnapshot
        let end: Date
    }

    private struct DayKey: Hashable {
        let era: Int
        let year: Int
        let month: Int
        let day: Int
    }
}
