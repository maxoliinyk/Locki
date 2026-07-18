//
//  PlacePresentationTests.swift
//  LockiTests
//
//  Created by Max Oliinyk on 18.07.2026.
//

import Foundation
import Testing
@testable import Locki

@Suite("Place presentation")
struct PlacePresentationTests {
    @Test("Ongoing visits contribute to live place totals")
    func ongoingVisitDuration() {
        let placeID = UUID()
        let now = Date(timeIntervalSince1970: 30_000)
        let metrics = PlacePresentation.metrics(
            visits: [visit(placeID: placeID, arrival: now - 27_360)],
            now: now
        )

        #expect(metrics[placeID]?.totalDuration == 27_360)
        #expect(metrics[placeID]?.visitCount == 1)
        #expect(metrics[placeID]?.distinctDayCount == 1)
        #expect(metrics[placeID]?.countSummary == "1 visit · 1 day")
    }

    @Test("Completed and ongoing visits combine without using stale stored totals")
    func combinedVisitDuration() {
        let placeID = UUID()
        let now = Date(timeIntervalSince1970: 100_000)
        let metrics = PlacePresentation.metrics(
            visits: [
                visit(placeID: placeID, arrival: now - 10_800, departure: now - 7_200),
                visit(placeID: placeID, arrival: now - 7_200),
            ],
            now: now
        )

        #expect(metrics[placeID]?.totalDuration == 10_800)
        #expect(metrics[placeID]?.visitCount == 2)
        #expect(metrics[placeID]?.countSummary == "2 visits · 1 day")
    }

    @Test("Excluded, future, and invalid visits do not affect totals")
    func ignoredVisits() {
        let placeID = UUID()
        let now = Date(timeIntervalSince1970: 100_000)
        let metrics = PlacePresentation.metrics(
            visits: [
                visit(placeID: placeID, arrival: now - 3_600, isExcluded: true),
                visit(placeID: placeID, arrival: now + 60),
                visit(placeID: placeID, arrival: now - 60, departure: now - 120),
            ],
            now: now
        )

        #expect(metrics[placeID] == nil)
    }

    @Test("Visits remain separated by place")
    func separatePlaces() {
        let firstPlace = UUID()
        let secondPlace = UUID()
        let now = Date(timeIntervalSince1970: 100_000)
        let metrics = PlacePresentation.metrics(
            visits: [
                visit(placeID: firstPlace, arrival: now - 60),
                visit(placeID: secondPlace, arrival: now - 120),
            ],
            now: now
        )

        #expect(metrics[firstPlace]?.totalDuration == 60)
        #expect(metrics[secondPlace]?.totalDuration == 120)
    }

    @Test("Durations use spaced localized components without commas")
    func durationFormatting() {
        let locale = Locale(identifier: "en_US")

        #expect(0.0.formattedDuration(locale: locale) == "0 min")
        #expect(59.0.formattedDuration(locale: locale) == "0 min")
        #expect(60.0.formattedDuration(locale: locale) == "1 min")
        #expect(3_600.0.formattedDuration(locale: locale) == "1 hr")
        #expect(27_360.0.formattedDuration(locale: locale) == "7 hr 36 min")
        #expect(!27_360.0.formattedDuration(locale: locale).contains(","))
        #expect((-1.0).formattedDuration(locale: locale) == "0 min")
        #expect(Double.infinity.formattedDuration(locale: locale) == "0 min")
    }

    private func visit(
        placeID: UUID,
        arrival: Date,
        departure: Date? = nil,
        isExcluded: Bool = false
    ) -> PlaceVisitPresentationSnapshot {
        PlaceVisitPresentationSnapshot(
            placeID: placeID,
            arrivalDate: arrival,
            departureDate: departure,
            timeZoneIdentifier: "UTC",
            isExcluded: isExcluded
        )
    }
}
