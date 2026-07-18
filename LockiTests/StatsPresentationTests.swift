//
//  StatsPresentationTests.swift
//  LockiTests
//
//  Created by Max Oliinyk on 18.07.2026.
//

import Foundation
import Testing
@testable import Locki

@Suite("Stats presentation")
struct StatsPresentationTests {
    private let calendar = Calendar(identifier: .gregorian)

    @Test("Day has an overview but no redundant chart")
    func dayPresentation() throws {
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 18)))
        let days = [snapshot(start, distance: 1_200, trips: 2, visits: 3)]
        let range = DateInterval(start: start, duration: 86_400)

        #expect(StatsPresentation.overview(days: days, calendar: calendar).distanceMeters == 1_200)
        #expect(StatsPresentation.overview(days: days, calendar: calendar).visitCount == 3)
        #expect(StatsPresentation.chartGranularity(for: .day, range: range, calendar: calendar) == nil)
    }

    @Test("Week and month use daily buckets")
    func dailyGranularity() throws {
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 1)))
        let range = DateInterval(start: start, duration: 31 * 86_400)

        #expect(StatsPresentation.chartGranularity(for: .week, range: range, calendar: calendar) == .day)
        #expect(StatsPresentation.chartGranularity(for: .month, range: range, calendar: calendar) == .day)
    }

    @Test("Year combines days into ordered unique monthly buckets")
    func monthlyBuckets() throws {
        let january = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 2)))
        let laterJanuary = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 20)))
        let february = try #require(calendar.date(from: DateComponents(year: 2026, month: 2, day: 1)))
        let buckets = StatsPresentation.distanceBuckets(
            days: [snapshot(february, distance: 300), snapshot(january, distance: 100), snapshot(laterJanuary, distance: 200, completeness: 0.5)],
            granularity: .month,
            calendar: calendar
        )

        #expect(buckets.count == 2)
        #expect(buckets.map(\.distanceMeters) == [300, 300])
        #expect(buckets.map(\.completeness) == [0.5, 1])
        #expect(buckets[0].start < buckets[1].start)
    }

    @Test("Long all-time histories adapt to yearly buckets")
    func allTimeGranularity() throws {
        let start = try #require(calendar.date(from: DateComponents(year: 2020, month: 1, day: 1)))
        let shortEnd = try #require(calendar.date(from: DateComponents(year: 2022, month: 1, day: 1)))
        let longEnd = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1)))

        #expect(StatsPresentation.chartGranularity(for: .all, range: DateInterval(start: start, end: shortEnd), calendar: calendar) == .month)
        #expect(StatsPresentation.chartGranularity(for: .all, range: DateInterval(start: start, end: longEnd), calendar: calendar) == .year)
    }

    @Test("Range filtering excludes both boundaries correctly")
    func rangeBoundaries() throws {
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 7)))
        let end = try #require(calendar.date(byAdding: .day, value: 7, to: start))
        let selected = StatsPresentation.days(
            [
                snapshot(try #require(calendar.date(byAdding: .day, value: -1, to: start))),
                snapshot(start),
                snapshot(try #require(calendar.date(byAdding: .day, value: 6, to: start))),
                snapshot(end),
            ],
            in: DateInterval(start: start, end: end)
        )

        #expect(selected.map(\.dayStart) == [start, calendar.date(byAdding: .day, value: 6, to: start)])
    }

    @Test("Empty periods produce zero overview and no buckets")
    func emptyPeriod() {
        #expect(StatsPresentation.overview(days: [], calendar: calendar) == .zero)
        #expect(StatsPresentation.distanceBuckets(days: [], granularity: .day, calendar: calendar).isEmpty)
    }

    private func snapshot(
        _ date: Date,
        distance: Double = 0,
        trips: Int = 0,
        visits: Int = 0,
        completeness: Double = 1
    ) -> StatsDaySnapshot {
        StatsDaySnapshot(
            dayStart: date,
            distanceMeters: distance,
            movingDuration: distance,
            placeDuration: distance,
            tripCount: trips,
            visitCount: visits,
            completeness: completeness
        )
    }
}
