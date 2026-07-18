//
//  JournalPresentationTests.swift
//  LockiTests
//
//  Created by Max Oliinyk on 18.07.2026.
//

import Foundation
import Testing
@testable import Locki

@Suite("Journal presentation")
struct JournalPresentationTests {
    @Test("Records intersect a range using half-open boundaries")
    func rangeIntersectionBoundaries() throws {
        let range = DateInterval(start: date(10), end: date(20))

        #expect(JournalPresentation.overlaps(start: date(5), end: date(11), range: range, now: date(30)))
        #expect(JournalPresentation.overlaps(start: date(19), end: date(25), range: range, now: date(30)))
        #expect(!JournalPresentation.overlaps(start: date(5), end: date(10), range: range, now: date(30)))
        #expect(!JournalPresentation.overlaps(start: date(20), end: date(25), range: range, now: date(30)))
    }

    @Test("Ongoing records intersect current and later ranges")
    func ongoingRecords() throws {
        #expect(
            JournalPresentation.overlaps(
                start: date(5),
                end: nil,
                range: DateInterval(start: date(10), end: date(20)),
                now: date(30)
            )
        )
        #expect(
            !JournalPresentation.overlaps(
                start: date(25),
                end: nil,
                range: DateInterval(start: date(10), end: date(20)),
                now: date(30)
            )
        )
    }

    @Test("Timeline grouping is deterministic and respects stored time zones")
    func timelineGrouping() throws {
        let first = try #require(ISO8601DateFormatter().date(from: "2026-07-18T00:30:00Z"))
        let second = try #require(ISO8601DateFormatter().date(from: "2026-07-18T08:30:00Z"))
        let descriptors = [
            JournalTimelineDescriptor(id: "later", date: second, timeZoneIdentifier: "Europe/Berlin"),
            JournalTimelineDescriptor(id: "earlier-b", date: first, timeZoneIdentifier: "America/Los_Angeles"),
            JournalTimelineDescriptor(id: "earlier-a", date: first, timeZoneIdentifier: "America/Los_Angeles"),
        ]

        let groups = JournalPresentation.dayGroups(descriptors, calendar: utcCalendar)

        #expect(groups.count == 2)
        #expect(groups[0].timeZoneIdentifier == "America/Los_Angeles")
        #expect(groups[0].itemIDs == ["earlier-a", "earlier-b"])
        #expect(groups[1].timeZoneIdentifier == "Europe/Berlin")
        #expect(groups[1].itemIDs == ["later"])
    }

    @Test("Route reduction stays within budget and preserves endpoints")
    func routeReduction() {
        let routes = [points(0..<20), points(100..<120), points(200..<220)]

        let reduced = JournalPresentation.reducedRoutes(routes, pointLimit: 12)

        #expect(reduced.flatMap { $0 }.count <= 12)
        #expect(reduced.count == 3)
        #expect(reduced[0].first == routes[0].first)
        #expect(reduced[0].last == routes[0].last)
        #expect(reduced[1].first == routes[1].first)
        #expect(reduced[1].last == routes[1].last)
        #expect(reduced == JournalPresentation.reducedRoutes(routes, pointLimit: 12))
    }

    @Test("Route reduction bounds route count and handles tiny budgets")
    func routeCountReduction() {
        let routes = (0..<10).map { points(($0 * 10)..<($0 * 10 + 5)) }
        let reduced = JournalPresentation.reducedRoutes(routes, pointLimit: 8)

        #expect(reduced.count == 4)
        #expect(reduced.flatMap { $0 }.count <= 8)
        #expect(reduced.allSatisfy { $0.count >= 2 })
        #expect(JournalPresentation.reducedRoutes(routes, pointLimit: 1).isEmpty)
        #expect(JournalPresentation.reducedRoutes([], pointLimit: 100).isEmpty)
    }

    @Test("Display sampling is bounded, stable, and keeps endpoints")
    func displaySampling() {
        #expect(JournalPresentation.sampledIndices(count: 10, limit: 4) == [0, 3, 6, 9])
        #expect(JournalPresentation.sampledIndices(count: 3, limit: 10) == [0, 1, 2])
        #expect(JournalPresentation.sampledIndices(count: 10, limit: 1) == [0])
        #expect(JournalPresentation.sampledIndices(count: 0, limit: 10).isEmpty)
        #expect(JournalPresentation.sampledIndices(count: 10, limit: 0).isEmpty)
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private func points(_ values: Range<Int>) -> [HistoryPoint] {
        values.map { value in
            HistoryPoint(
                sample: HistoryLocationSample(
                    coordinate: GeoCoordinate(latitude: Double(value) / 1_000, longitude: 0),
                    horizontalAccuracyMeters: 5,
                    timestamp: date(TimeInterval(value)),
                    timeZoneIdentifier: "UTC"
                )
            )
        }
    }
}
