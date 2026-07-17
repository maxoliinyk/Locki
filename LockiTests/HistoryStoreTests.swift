//
//  HistoryStoreTests.swift
//  LockiTests
//
//  Created by Max Oliinyk on 17.07.2026.
//

import Foundation
import SwiftData
import Testing
@testable import Locki

@Suite("Private history persistence")
struct HistoryStoreTests {
    @Test("Accepted movement persists reduced trajectory and statistics")
    func movementPersistence() async throws {
        let store = HistoryStore(modelContainer: try makeContainer())
        let start = Date(timeIntervalSinceReferenceDate: 200_000)
        _ = try await store.setEnabled(true, at: start)
        _ = try await store.ingest(.sample(sample(longitude: 13.4000, timestamp: start)), now: start)
        _ = try await store.ingest(.sample(sample(longitude: 13.4020, timestamp: start + 60)), now: start + 60)
        let overview = try await store.ingest(.sample(sample(longitude: 13.4040, timestamp: start + 120)), now: start + 120)

        #expect(overview.distanceMeters > 200)
        #expect(overview.tripCount == 1)
        #expect(overview.trackedDayCount == 1)
        #expect(overview.encodedByteCount > 0)
    }

    @Test("Missing simulator speeds are inferred and classify a sufficiently sampled walk")
    func inferredWalkingSpeed() async throws {
        let store = HistoryStore(modelContainer: try makeContainer())
        let start = Date(timeIntervalSinceReferenceDate: 250_000)
        _ = try await store.setEnabled(true, at: start)
        for index in 0..<4 {
            _ = try await store.ingest(
                .sample(
                    sample(
                        longitude: 13.40 + Double(index) * 0.0003,
                        speed: nil,
                        timestamp: start + Double(index * 10)
                    )
                ),
                now: start + Double(index * 10)
            )
        }
        _ = try await store.setEnabled(false, at: start + 40)
        let trip = try #require(try await decodedExport(store).trips.first)
        #expect(trip.mode == .walking)
        #expect(trip.points.compactMap(\.speedMetersPerSecond).count >= 3)
    }

    @Test("Ten-minute dwell creates an inferred place and visit")
    func visitPersistence() async throws {
        let store = HistoryStore(modelContainer: try makeContainer())
        let start = Date(timeIntervalSinceReferenceDate: 300_000)
        _ = try await store.setEnabled(true, at: start)
        _ = try await store.ingest(.sample(sample(speed: 0, timestamp: start)), now: start)
        let overview = try await store.ingest(.sample(sample(speed: 0, timestamp: start + 600)), now: start + 600)

        #expect(overview.visitCount == 1)
        #expect(overview.placeCount == 1)
    }

    @Test("Stationary silence confirms a visit after ten minutes")
    func stationarySilenceConfirmsVisit() async throws {
        let store = HistoryStore(modelContainer: try makeContainer())
        let start = Date(timeIntervalSinceReferenceDate: 310_000)
        _ = try await store.setEnabled(true, at: start)
        _ = try await store.ingest(.sample(sample(speed: 0, timestamp: start)), now: start)

        let beforeThreshold = try await store.ingest(.dwellCheck(start + 599), now: start + 599)
        #expect(beforeThreshold.visitCount == 0)

        let atThreshold = try await store.ingest(.dwellCheck(start + 600), now: start + 600)
        #expect(atThreshold.visitCount == 1)
        #expect(atThreshold.placeCount == 1)
        #expect(try await decodedExport(store).visits.first?.arrivalDate == start)

        let repeatedCheck = try await store.ingest(.dwellCheck(start + 900), now: start + 900)
        #expect(repeatedCheck.visitCount == 1)
    }

    @Test("Movement cancels a pending silent dwell")
    func movementCancelsSilentDwell() async throws {
        let store = HistoryStore(modelContainer: try makeContainer())
        let start = Date(timeIntervalSinceReferenceDate: 315_000)
        _ = try await store.setEnabled(true, at: start)
        _ = try await store.ingest(.sample(sample(speed: 0, timestamp: start)), now: start)
        _ = try await store.ingest(
            .sample(sample(longitude: 13.402, speed: 3, timestamp: start + 300)),
            now: start + 300
        )

        let overview = try await store.ingest(.dwellCheck(start + 600), now: start + 600)
        #expect(overview.visitCount == 0)
        #expect(overview.placeCount == 0)
    }

    @Test("A visit closes only after five continuous minutes outside")
    func visitExitHysteresis() async throws {
        let store = HistoryStore(modelContainer: try makeContainer())
        let start = Date(timeIntervalSinceReferenceDate: 325_000)
        _ = try await store.setEnabled(true, at: start)
        _ = try await store.ingest(.sample(sample(speed: 0, timestamp: start)), now: start)
        _ = try await store.ingest(.sample(sample(speed: 0, timestamp: start + 600)), now: start + 600)
        _ = try await store.ingest(.sample(sample(longitude: 13.402, speed: 2, timestamp: start + 660)), now: start + 660)
        _ = try await store.ingest(.sample(sample(longitude: 13.402, speed: 2, timestamp: start + 959)), now: start + 959)

        var export = try await decodedExport(store)
        #expect(export.visits.first?.departureDate == nil)

        _ = try await store.ingest(.sample(sample(longitude: 13.402, speed: 2, timestamp: start + 960)), now: start + 960)
        export = try await decodedExport(store)
        #expect(export.visits.first?.departureDate == start + 660)
    }

    @Test("Returning before five minutes cancels pending departure")
    func visitReentryCancelsExit() async throws {
        let store = HistoryStore(modelContainer: try makeContainer())
        let start = Date(timeIntervalSinceReferenceDate: 350_000)
        _ = try await store.setEnabled(true, at: start)
        _ = try await store.ingest(.sample(sample(speed: 0, timestamp: start)), now: start)
        _ = try await store.ingest(.sample(sample(speed: 0, timestamp: start + 600)), now: start + 600)
        _ = try await store.ingest(.sample(sample(longitude: 13.402, speed: 2, timestamp: start + 660)), now: start + 660)
        _ = try await store.ingest(.sample(sample(speed: 0, timestamp: start + 800)), now: start + 800)
        _ = try await store.ingest(.sample(sample(speed: 0, timestamp: start + 1_000)), now: start + 1_000)
        #expect(try await decodedExport(store).visits.first?.departureDate == nil)
    }

    @Test("Disabling history closes an open visit at the gap boundary")
    func disablingClosesOpenVisit() async throws {
        let store = HistoryStore(modelContainer: try makeContainer())
        let start = Date(timeIntervalSinceReferenceDate: 375_000)
        _ = try await store.setEnabled(true, at: start)
        _ = try await store.ingest(.sample(sample(speed: 0, timestamp: start)), now: start)
        _ = try await store.ingest(.sample(sample(speed: 0, timestamp: start + 600)), now: start + 600)
        _ = try await store.setEnabled(false, at: start + 700)
        #expect(try await decodedExport(store).visits.first?.departureDate == start + 700)
    }

    @Test("Repeated park visits merge while a nearby distinct venue stays separate")
    func recurringPlaceClustering() async throws {
        let store = HistoryStore(modelContainer: try makeContainer())
        let start = Date(timeIntervalSinceReferenceDate: 390_000)
        _ = try await store.setEnabled(true, at: start)
        for day in 0..<3 {
            _ = try await store.ingest(.visit(systemVisit(longitude: 13.40, start: start + Double(day * 86_400))))
        }
        _ = try await store.ingest(.visit(systemVisit(longitude: 13.402, start: start + 4 * 86_400)))
        let export = try await decodedExport(store)
        #expect(export.places.count == 2)
        #expect(Dictionary(grouping: export.visits, by: \.placeID).values.map(\.count).sorted() == [1, 3])
    }

    @Test("JSON and GPX exports contain only persisted reduced history")
    func exports() async throws {
        let store = HistoryStore(modelContainer: try makeContainer())
        let start = Date(timeIntervalSinceReferenceDate: 400_000)
        _ = try await store.setEnabled(true, at: start)
        _ = try await store.ingest(.sample(sample(timestamp: start)), now: start)
        _ = try await store.ingest(.sample(sample(longitude: 13.402, timestamp: start + 60)), now: start + 60)

        let json = try await store.exportJSON()
        let gpx = try await store.exportGPX()
        #expect(String(decoding: json, as: UTF8.self).contains("\"schemaVersion\" : 1"))
        #expect(String(decoding: gpx, as: UTF8.self).contains("<trkpt"))
    }

    @Test("Deleting all history leaves an empty reusable store")
    func deleteAll() async throws {
        let store = HistoryStore(modelContainer: try makeContainer())
        let start = Date(timeIntervalSinceReferenceDate: 500_000)
        _ = try await store.setEnabled(true, at: start)
        _ = try await store.ingest(.sample(sample(timestamp: start)), now: start)
        let overview = try await store.deleteAll()
        #expect(overview.tripCount == 0)
        #expect(overview.visitCount == 0)
        #expect(overview.encodedByteCount == 0)
    }

    @Test("Duplicate callbacks are idempotent and delayed callbacks are inserted chronologically")
    func duplicateAndDelayedSamples() async throws {
        let store = HistoryStore(modelContainer: try makeContainer())
        let start = Date(timeIntervalSinceReferenceDate: 600_000)
        _ = try await store.setEnabled(true, at: start)
        let first = sample(timestamp: start)
        _ = try await store.ingest(.sample(first), now: start)
        _ = try await store.ingest(.sample(sample(longitude: 13.404, timestamp: start + 120)), now: start + 120)
        _ = try await store.ingest(.sample(first), now: start + 120)
        _ = try await store.ingest(.sample(sample(longitude: 13.402, timestamp: start + 60)), now: start + 120)

        let data = try await store.exportJSON()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(HistoryExport.self, from: data)
        let points = export.trips.flatMap(\.points)
        #expect(points.count == 3)
        #expect(points.map(\.timestamp) == points.map(\.timestamp).sorted())
    }

    @Test("Disabling history creates a bounded gap and starts a fresh segment")
    func disablingHistorySeparatesSegments() async throws {
        let store = HistoryStore(modelContainer: try makeContainer())
        let start = Date(timeIntervalSinceReferenceDate: 650_000)
        _ = try await store.setEnabled(true, at: start)
        _ = try await store.ingest(.sample(sample(timestamp: start)), now: start)
        _ = try await store.ingest(.sample(sample(longitude: 13.402, timestamp: start + 60)), now: start + 60)
        _ = try await store.setEnabled(false, at: start + 70)

        _ = try await store.ingest(.sample(sample(longitude: 13.406, timestamp: start + 90)), now: start + 90)
        _ = try await store.ingest(
            .visit(
                SystemVisitSample(
                    coordinate: GeoCoordinate(latitude: 52.52, longitude: 13.406),
                    horizontalAccuracyMeters: 20,
                    arrivalDate: start + 80,
                    departureDate: start + 100,
                    timeZoneIdentifier: "Europe/Berlin"
                )
            )
        )
        _ = try await store.setEnabled(true, at: start + 130)
        _ = try await store.ingest(.sample(sample(longitude: 13.410, timestamp: start + 130)), now: start + 130)
        _ = try await store.ingest(.sample(sample(longitude: 13.412, timestamp: start + 190)), now: start + 190)
        _ = try await store.setEnabled(false, at: start + 200)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(HistoryExport.self, from: await store.exportJSON())

        #expect(export.trips.count == 2)
        #expect(export.trips.allSatisfy { $0.points.count == 2 })
        #expect(export.visits.isEmpty)
        #expect(!export.trips.flatMap(\.points).contains { $0.timestamp == start + 90 })
        #expect(export.gaps.contains { $0.startedAt == start + 70 && $0.endedAt == start + 130 })
    }

    @Test("Deleting a date range trims trajectory instead of deleting outside points")
    func rangeDeletionTrims() async throws {
        let store = HistoryStore(modelContainer: try makeContainer())
        let start = Date(timeIntervalSinceReferenceDate: 700_000)
        _ = try await store.setEnabled(true, at: start)
        for minute in 0...4 {
            _ = try await store.ingest(
                .sample(sample(longitude: 13.40 + Double(minute) * 0.001, timestamp: start + Double(minute * 60))),
                now: start + Double(minute * 60)
            )
        }
        _ = try await store.deleteHistory(from: start + 90, to: start + 210)

        let data = try await store.exportJSON()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(HistoryExport.self, from: data)
        let dates = export.trips.flatMap(\.points).map(\.timestamp)
        #expect(dates.allSatisfy { $0 < start + 90 || $0 >= start + 210 })
        #expect(dates.contains(start))
        #expect(dates.contains(start + 240))
    }

    @Test("Duration-only trips count and summary rebuilds preserve gap completeness")
    func summaryRebuildPreservesMeaningfulTripsAndGaps() async throws {
        let container = try makeContainer()
        let store = HistoryStore(modelContainer: container)
        let start = Date(timeIntervalSinceReferenceDate: 750_000)
        _ = try await store.setEnabled(true, at: start)
        _ = try await store.ingest(.sample(sample(speed: 1, timestamp: start)), now: start)
        _ = try await store.ingest(.sample(sample(longitude: 13.40005, speed: 1, timestamp: start + 65)), now: start + 65)
        _ = try await store.ingest(.sample(sample(longitude: 13.40010, speed: 1, timestamp: start + 130)), now: start + 130)
        _ = try await store.setEnabled(false, at: start + 140)
        _ = try await store.setEnabled(true, at: start + 200)
        let overview = try await store.deleteTrip(id: UUID())

        let summaries = try container.mainContext.fetch(FetchDescriptor<HistoryDailySummaryRecord>())
        let summary = try #require(summaries.first)
        #expect(overview.tripCount == 1)
        #expect(summary.tripCount == 1)
        #expect(summary.gapDuration == 60)
        #expect(summary.completeness < 1)
    }

    @Test("A zero-duration tracking toggle does not leave an ongoing gap")
    func zeroDurationToggleIsIdempotent() async throws {
        let store = HistoryStore(modelContainer: try makeContainer())
        let date = Date(timeIntervalSinceReferenceDate: 775_000)
        _ = try await store.setEnabled(true, at: date)
        _ = try await store.setEnabled(false, at: date)
        let overview = try await store.setEnabled(true, at: date)
        #expect(overview.gapCount == 0)
    }

    @Test("Tracking gaps are divided across local calendar days")
    func gapSpansCalendarDays() async throws {
        let container = try makeContainer()
        let store = HistoryStore(modelContainer: container)
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: 900_000))
        let midnight = try #require(calendar.date(byAdding: .day, value: 1, to: day))
        let start = midnight - 1_800
        let end = midnight + 1_800
        _ = try await store.setEnabled(true, at: start - 1)
        _ = try await store.setEnabled(false, at: start)
        _ = try await store.setEnabled(true, at: end)
        _ = try await store.deleteTrip(id: UUID())

        let gapSummaries = try container.mainContext.fetch(FetchDescriptor<HistoryDailySummaryRecord>())
            .filter { $0.gapDuration > 0 }
        #expect(gapSummaries.count == 2)
        #expect(gapSummaries.reduce(0) { $0 + $1.gapDuration } == 3_600)
    }

    @Test("GPX export escapes user labels with unicode and XML punctuation")
    func exportEscaping() async throws {
        let store = HistoryStore(modelContainer: try makeContainer())
        let start = Date(timeIntervalSinceReferenceDate: 800_000)
        _ = try await store.setEnabled(true, at: start)
        _ = try await store.ingest(
            .visit(
                SystemVisitSample(
                    coordinate: GeoCoordinate(latitude: 52.52, longitude: 13.40),
                    horizontalAccuracyMeters: 20,
                    arrivalDate: start,
                    departureDate: start + 900,
                    timeZoneIdentifier: "Europe/Berlin"
                )
            )
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(HistoryExport.self, from: await store.exportJSON())
        let place = try #require(export.places.first)
        try await store.updatePlace(id: place.id, name: "Café & <Park> 🗺️", category: nil)
        let gpx = String(decoding: try await store.exportGPX(), as: UTF8.self)
        #expect(gpx.contains("Café &amp; &lt;Park&gt; 🗺️"))
    }

    private func sample(
        longitude: Double = 13.40,
        speed: Double? = 2,
        timestamp: Date
    ) -> HistoryLocationSample {
        HistoryLocationSample(
            coordinate: GeoCoordinate(latitude: 52.52, longitude: longitude),
            horizontalAccuracyMeters: 8,
            speedMetersPerSecond: speed,
            courseDegrees: 90,
            timestamp: timestamp,
            timeZoneIdentifier: "Europe/Berlin"
        )
    }

    private func systemVisit(longitude: Double, start: Date) -> SystemVisitSample {
        SystemVisitSample(
            coordinate: GeoCoordinate(latitude: 52.52, longitude: longitude),
            horizontalAccuracyMeters: 10,
            arrivalDate: start,
            departureDate: start + 1_800,
            timeZoneIdentifier: "Europe/Berlin"
        )
    }

    private func decodedExport(_ store: HistoryStore) async throws -> HistoryExport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(HistoryExport.self, from: await store.exportJSON())
    }

    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: HistoryMetadataRecord.self,
            TrajectoryChunkRecord.self,
            HistoryTripRecord.self,
            HistoryVisitRecord.self,
            HistoryPlaceRecord.self,
            HistoryRoutePatternRecord.self,
            HistoryDailySummaryRecord.self,
            HistoryGapRecord.self,
            PlaceSuggestionPreferenceRecord.self,
            configurations: configuration
        )
    }
}
