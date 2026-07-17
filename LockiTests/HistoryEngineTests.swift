//
//  HistoryEngineTests.swift
//  LockiTests
//
//  Created by Max Oliinyk on 17.07.2026.
//

import Foundation
import Testing
@testable import Locki

@Suite("Private history engines")
struct HistoryEngineTests {
    private let now = Date(timeIntervalSinceReferenceDate: 100_000)

    @Test("History filter rejects approximate, inaccurate, stale, future, and impossible-speed fixes")
    func sampleFiltering() {
        let filter = HistorySampleFilter()
        #expect(filter.accepts(sample(), now: now))
        #expect(!filter.accepts(sample(accuracy: 36), now: now))
        #expect(!filter.accepts(sample(precise: false), now: now))
        #expect(!filter.accepts(sample(speed: 81), now: now))
        #expect(!filter.accepts(sample(timestamp: now.addingTimeInterval(-121)), now: now))
        #expect(!filter.accepts(sample(timestamp: now.addingTimeInterval(11)), now: now))
    }

    @Test("Trajectory reducer retains distance, interval, heading, and speed-class changes")
    func reductionBoundaries() {
        let reducer = TrajectoryReducer()
        let first = HistoryPoint(sample: sample())
        #expect(!reducer.shouldRetain(sample(longitude: 13.40001, timestamp: now.addingTimeInterval(10)), after: first))
        #expect(reducer.shouldRetain(sample(longitude: 13.4003, timestamp: now.addingTimeInterval(10)), after: first))
        #expect(reducer.shouldRetain(sample(timestamp: now.addingTimeInterval(30)), after: first))
        #expect(reducer.shouldRetain(sample(course: 25, timestamp: now.addingTimeInterval(10)), after: first))
        #expect(reducer.shouldRetain(sample(speed: 9, timestamp: now.addingTimeInterval(10)), after: first))
    }

    @Test("Persisted points are quantized and round-trip through binary encoding")
    func pointEncoding() throws {
        let point = HistoryPoint(sample: sample(longitude: 13.400006, speed: 1.26, course: 12))
        #expect(point.longitudeE5 == 1_340_001)
        #expect(point.speedMetersPerSecond == 1.5)
        #expect(point.courseDegrees == 10)
        let data = try HistoryPointCodec.encode([point])
        #expect(try HistoryPointCodec.decode(data) == [point])
    }

    @Test("Movement classification avoids car-versus-transit claims")
    func movementModes() {
        let reducer = TrajectoryReducer()
        #expect(reducer.movementMode(for: Array(repeating: 1.4, count: 12)).mode == .walking)
        #expect(reducer.movementMode(for: Array(repeating: 5.0, count: 16)).mode == .cycling)
        #expect(reducer.movementMode(for: Array(repeating: 18.0, count: 16)).mode == .motorized)
        #expect(reducer.movementMode(for: [1]).mode == .unknown)
    }

    @Test("Visit inference uses minimum dwell and bounded accuracy-aware radius")
    func visitInference() {
        let engine = VisitInferenceEngine()
        #expect(engine.radius(forAccuracy: 5) == 35)
        #expect(engine.radius(forAccuracy: 100) == 100)
        #expect(!engine.qualifies(startedAt: now, current: now.addingTimeInterval(599)))
        #expect(engine.qualifies(startedAt: now, current: now.addingTimeInterval(600)))
    }

    @Test("Frequent places require visits, distinct days, and total time")
    func frequentPlaceBoundaries() {
        let ranker = FrequentPlaceRanker()
        let qualified = placeSnapshot(duration: 1_800, visits: 3, days: 2)
        #expect(ranker.qualifies(qualified))
        #expect(!ranker.qualifies(placeSnapshot(duration: 1_799, visits: 3, days: 2)))
        #expect(!ranker.qualifies(placeSnapshot(duration: 1_800, visits: 2, days: 2)))
        #expect(!ranker.qualifies(placeSnapshot(duration: 1_800, visits: 3, days: 1)))
        #expect(ranker.qualifies(placeSnapshot(duration: 1_800, visits: 3, days: 2, favorite: false)))
    }

    @Test("Place analytics includes a live visit and splits period time into calendar buckets")
    func placeAnalytics() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let firstDay = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 16, hour: 23, minute: 30)))
        let midnight = try #require(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: firstDay)))
        let now = midnight + 3_600
        let visit = PlaceVisitSnapshot(
            id: UUID(),
            arrivalDate: firstDay,
            departureDate: nil,
            timeZoneIdentifier: "Europe/Berlin",
            isExcluded: false
        )
        let analytics = PlaceAnalyticsEngine().snapshot(visits: [visit], periodStart: .distantPast, now: now)

        #expect(analytics.currentVisit?.id == visit.id)
        #expect(analytics.allTimeDuration == 5_400)
        #expect(analytics.periodDuration == 5_400)
        #expect(analytics.trend.count == 2)
        #expect(analytics.trend.reduce(0) { $0 + $1.duration } == 5_400)
    }

    @Test("Home and work suggestions require repeat schedules and a dominant candidate")
    func placeLabelSuggestions() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let base = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6)))
        let homeID = UUID()
        let workID = UUID()
        let homeVisits = (0..<3).map { day in
            labelVisit(start: base + Double(day * 86_400 + 21 * 3_600), duration: 8 * 3_600)
        }
        let workVisits = (0..<3).map { day in
            labelVisit(start: base + Double(day * 86_400 + 9 * 3_600), duration: 8 * 3_600)
        }
        let result = PlaceLabelSuggestionEngine().suggestions(
            for: [
                PlaceSuggestionInput(id: homeID, visits: homeVisits, dismissedSuggestion: nil),
                PlaceSuggestionInput(id: workID, visits: workVisits, dismissedSuggestion: nil),
            ],
            now: base + 7 * 86_400
        )
        #expect(result[homeID] == .home)
        #expect(result[workID] == .work)
    }

    @Test("Route matching accepts reversed equivalent paths and rejects distant corridors")
    func routeSimilarity() {
        let engine = RouteSimilarityEngine()
        let first = [point(latitude: 52.52, longitude: 13.40), point(latitude: 52.52, longitude: 13.405)]
        let reversed = Array(first.reversed())
        let distant = [point(latitude: 52.53, longitude: 13.40), point(latitude: 52.53, longitude: 13.405)]
        #expect(engine.matches(first, reversed))
        #expect(!engine.matches(first, distant))
    }

    private func sample(
        latitude: Double = 52.52,
        longitude: Double = 13.40,
        accuracy: Double = 8,
        speed: Double? = 1.4,
        course: Double? = 0,
        timestamp: Date? = nil,
        precise: Bool = true
    ) -> HistoryLocationSample {
        HistoryLocationSample(
            coordinate: GeoCoordinate(latitude: latitude, longitude: longitude),
            horizontalAccuracyMeters: accuracy,
            speedMetersPerSecond: speed,
            courseDegrees: course,
            timestamp: timestamp ?? now,
            timeZoneIdentifier: "Europe/Berlin",
            hasPreciseAccuracy: precise
        )
    }

    private func point(latitude: Double, longitude: Double) -> HistoryPoint {
        HistoryPoint(sample: sample(latitude: latitude, longitude: longitude))
    }

    private func placeSnapshot(
        duration: TimeInterval,
        visits: Int,
        days: Int,
        favorite: Bool = false
    ) -> HistoryPlaceRecordSnapshot {
        HistoryPlaceRecordSnapshot(
            id: UUID(),
            name: "Place",
            totalDuration: duration,
            visitCount: visits,
            distinctDayCount: days,
            lastVisitAt: now,
            isFavorite: favorite,
            isExcluded: false
        )
    }

    private func labelVisit(start: Date, duration: TimeInterval) -> PlaceVisitSnapshot {
        PlaceVisitSnapshot(
            id: UUID(),
            arrivalDate: start,
            departureDate: start + duration,
            timeZoneIdentifier: "Europe/Berlin",
            isExcluded: false
        )
    }
}
