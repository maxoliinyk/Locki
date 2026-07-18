//
//  BackupArchiveTests.swift
//  LockiTests
//
//  Created by Max Oliinyk on 18.07.2026.
//

import Foundation
import SwiftData
import Testing
@testable import Locki

@Suite("Locki backup")
@MainActor
struct BackupArchiveTests {
    @Test("Full backup restores durable history and derived summaries")
    func fullRoundTrip() async throws {
        let source = try LockiPersistence.makeContainer(inMemory: true)
        let fixture = try seedCompleteHistory(in: source)
        let data = try await BackupStore(modelContainer: source).exportData(exportedAt: fixture.exportedAt)
        let target = try LockiPersistence.makeContainer(inMemory: true)

        let result = try await BackupStore(modelContainer: target).importData(data)

        #expect(result.insertedPlaces == 1)
        #expect(result.insertedTrips == 1)
        #expect(result.insertedVisits == 1)
        #expect(result.insertedRoutes == 1)
        #expect(result.insertedGaps == 1)
        #expect(result.insertedTrajectoryChunks == 1)
        #expect(result.mergedCoverageCells == 1)
        let places = try target.mainContext.fetch(FetchDescriptor<HistoryPlaceRecord>())
        let days = try target.mainContext.fetch(FetchDescriptor<HistoryDailySummaryRecord>())
        #expect(places.first?.name == "Home")
        #expect(places.first?.visitCount == 1)
        #expect(places.first?.totalDuration == 3_600)
        #expect(days.count == 1)
        #expect(days.first?.distanceMeters == 1_200)
        #expect(days.first?.visitCount == 1)
    }

    @Test("Export contains delayed points by expanding the trip interval")
    func exportNormalizesDelayedTrajectoryPoint() async throws {
        let container = try LockiPersistence.makeContainer(inMemory: true)
        let exportedAt = Date.now
        let trip = HistoryTripRecord(
            startedAt: exportedAt - 600,
            startTimeZoneIdentifier: TimeZone.current.identifier
        )
        trip.endedAt = exportedAt - 300
        container.mainContext.insert(trip)
        let delayedPoint = HistoryPoint(
            latitudeE5: 5_252_000,
            longitudeE5: 1_340_000,
            timestampSeconds: Int64((exportedAt - 120).timeIntervalSince1970),
            accuracyBucketMeters: 10,
            speedHalfMetersPerSecond: nil,
            courseFiveDegrees: nil,
            timeZoneIdentifier: TimeZone.current.identifier
        )
        container.mainContext.insert(
            try TrajectoryChunkRecord(tripID: trip.id, sequence: 0, points: [delayedPoint])
        )
        try container.mainContext.save()

        let data = try await BackupStore(modelContainer: container).exportData(exportedAt: exportedAt)
        let envelope = try BackupArchiveCodec.decode(data)
        let backedUpTrip = try #require(envelope.payload.trips.first)

        #expect(backedUpTrip.startedAt == trip.startedAt)
        #expect(backedUpTrip.endedAt == delayedPoint.timestamp)
        #expect(backedUpTrip.elapsedDuration == delayedPoint.timestamp.timeIntervalSince(trip.startedAt))
    }

    @Test("Export advances the snapshot date to contain open history")
    func exportContainsOpenHistoryWithClockSkew() async throws {
        let container = try LockiPersistence.makeContainer(inMemory: true)
        let exportedAt = Date.now
        let trip = HistoryTripRecord(
            startedAt: exportedAt - 60,
            startTimeZoneIdentifier: TimeZone.current.identifier
        )
        container.mainContext.insert(trip)
        let latestPoint = HistoryPoint(
            latitudeE5: 5_252_000,
            longitudeE5: 1_340_000,
            timestampSeconds: Int64(exportedAt.timeIntervalSince1970) + 5,
            accuracyBucketMeters: 10,
            speedHalfMetersPerSecond: nil,
            courseFiveDegrees: nil,
            timeZoneIdentifier: TimeZone.current.identifier
        )
        container.mainContext.insert(
            try TrajectoryChunkRecord(tripID: trip.id, sequence: 0, points: [latestPoint])
        )
        try container.mainContext.save()

        let data = try await BackupStore(modelContainer: container).exportData(exportedAt: exportedAt)
        let envelope = try BackupArchiveCodec.decode(data)

        #expect(envelope.exportedAt == latestPoint.timestamp)
        #expect(envelope.payload.trips.first?.endedAt == nil)
    }

    @Test("Repeated import is idempotent")
    func repeatedImport() async throws {
        let source = try LockiPersistence.makeContainer(inMemory: true)
        let fixture = try seedCompleteHistory(in: source)
        let data = try await BackupStore(modelContainer: source).exportData(exportedAt: fixture.exportedAt)
        let target = try LockiPersistence.makeContainer(inMemory: true)
        let store = BackupStore(modelContainer: target)

        _ = try await store.importData(data)
        let second = try await store.importData(data)

        #expect(second.insertedRecordCount == 0)
        #expect(second.mergedCoverageCells == 0)
        #expect(try target.mainContext.fetchCount(FetchDescriptor<HistoryPlaceRecord>()) == 1)
        #expect(try target.mainContext.fetchCount(FetchDescriptor<HistoryTripRecord>()) == 1)
    }

    @Test("Existing local edits and unrelated data are preserved")
    func localWinsConflicts() async throws {
        let source = try LockiPersistence.makeContainer(inMemory: true)
        let fixture = try seedCompleteHistory(in: source)
        let data = try await BackupStore(modelContainer: source).exportData(exportedAt: fixture.exportedAt)
        let target = try LockiPersistence.makeContainer(inMemory: true)
        let local = HistoryPlaceRecord(
            id: fixture.placeID,
            latitude: 1,
            longitude: 1,
            radiusMeters: 20,
            name: "My Local Name",
            labelSourceRawValue: "user"
        )
        local.isFavorite = false
        target.mainContext.insert(local)
        target.mainContext.insert(
            HistoryPlaceRecord(latitude: 2, longitude: 2, radiusMeters: 20, name: "Unrelated")
        )
        try target.mainContext.save()

        _ = try await BackupStore(modelContainer: target).importData(data)

        let places = try target.mainContext.fetch(FetchDescriptor<HistoryPlaceRecord>())
        let restoredLocal = try #require(places.first { $0.id == fixture.placeID })
        #expect(restoredLocal.name == "My Local Name")
        #expect(restoredLocal.labelSourceRawValue == "user")
        #expect(!restoredLocal.isFavorite)
        #expect(places.contains { $0.name == "Unrelated" })
    }

    @Test("Coverage masks merge by union")
    func coverageUnion() async throws {
        let target = try LockiPersistence.makeContainer(inMemory: true)
        var localMask = CoverageMask()
        localMask.insert(localX: 0, localY: 0)
        target.mainContext.insert(
            CoverageChunkRecord(
                snapshot: CoverageChunkSnapshot(
                    key: CoverageChunkKey(x: 1, y: 1, zoom: ExplorationConfiguration.streetPrecise.chunkZoom),
                    mask: localMask,
                    revision: 1
                )
            )
        )
        try target.mainContext.save()
        var importedMask = CoverageMask()
        importedMask.insert(localX: 1, localY: 0)
        let envelope = LockiBackupEnvelope(
            payload: emptyPayload(coverage: [
                BackupCoverageChunk(
                    x: 1,
                    y: 1,
                    zoom: ExplorationConfiguration.streetPrecise.chunkZoom,
                    maskData: importedMask.data
                ),
            ])
        )

        let result = try await BackupStore(modelContainer: target).importData(
            try BackupArchiveCodec.encode(envelope)
        )

        let record = try #require(target.mainContext.fetch(FetchDescriptor<CoverageChunkRecord>()).first)
        #expect(result.mergedCoverageCells == 1)
        #expect(CoverageMask(data: record.maskData).setBitCount == 2)
        #expect(try #require(target.mainContext.fetch(FetchDescriptor<ExplorationSummaryRecord>()).first).exploredCellCount == 2)
    }

    @Test("Open records are normalized on restore")
    func openRecordNormalization() async throws {
        let now = Date.now
        let tripID = UUID()
        let placeID = UUID()
        let envelope = LockiBackupEnvelope(
            exportedAt: now,
            payload: LockiBackupPayload(
                coverage: [],
                trajectory: [],
                trips: [backupTrip(id: tripID, startedAt: now - 600, endedAt: nil)],
                visits: [backupVisit(placeID: placeID, arrival: now - 300, departure: nil)],
                places: [backupPlace(id: placeID)],
                routes: [],
                gaps: [BackupGap(id: UUID(), startedAt: now - 60, endedAt: nil, reasonRawValue: HistoryGapReason.unavailable.rawValue)],
                suggestionPreferences: []
            )
        )
        let target = try LockiPersistence.makeContainer(inMemory: true)

        _ = try await BackupStore(modelContainer: target).importData(try BackupArchiveCodec.encode(envelope))

        #expect(try #require(target.mainContext.fetch(FetchDescriptor<HistoryTripRecord>()).first).endedAt == now)
        #expect(try #require(target.mainContext.fetch(FetchDescriptor<HistoryVisitRecord>()).first).departureDate == now)
        #expect(try #require(target.mainContext.fetch(FetchDescriptor<HistoryGapRecord>()).first).endedAt == now)
    }

    @Test("Empty backup restores into an empty store")
    func emptyRestore() async throws {
        let target = try LockiPersistence.makeContainer(inMemory: true)
        let data = try BackupArchiveCodec.encode(LockiBackupEnvelope(payload: emptyPayload()))

        let result = try await BackupStore(modelContainer: target).importData(data)

        #expect(result.insertedRecordCount == 0)
        #expect(result.mergedCoverageCells == 0)
    }

    @Test("Corrupt, unsupported, and dangling archives are rejected before mutation")
    func invalidArchives() async throws {
        #expect(throws: BackupArchiveError.invalidEncoding) {
            try BackupArchiveCodec.decode(Data("not a backup".utf8))
        }
        let unsupported = LockiBackupEnvelope(schemaVersion: 99, payload: emptyPayload())
        #expect(throws: BackupArchiveError.unsupportedVersion(99)) {
            try BackupArchiveCodec.validate(unsupported)
        }
        let dangling = LockiBackupEnvelope(
            payload: emptyPayload(visits: [backupVisit(placeID: UUID(), arrival: .now, departure: .now)])
        )
        #expect(throws: BackupArchiveError.danglingRelationship) {
            try BackupArchiveCodec.validate(dangling)
        }

        let target = try LockiPersistence.makeContainer(inMemory: true)
        do {
            _ = try await BackupStore(modelContainer: target).importData(
                try PropertyListEncoder().encode(dangling)
            )
            Issue.record("Invalid archive unexpectedly imported")
        } catch {
            #expect(error as? BackupArchiveError == .danglingRelationship)
        }
        #expect(try target.mainContext.fetchCount(FetchDescriptor<HistoryVisitRecord>()) == 0)
    }

    private func seedCompleteHistory(in container: ModelContainer) throws -> (placeID: UUID, exportedAt: Date) {
        let now = Calendar.current.startOfDay(for: .now) + 12 * 3_600
        let place = HistoryPlaceRecord(
            latitude: 52.52,
            longitude: 13.40,
            radiusMeters: 35,
            name: "Home",
            labelSourceRawValue: "user"
        )
        place.isFavorite = true
        container.mainContext.insert(place)
        let visit = HistoryVisitRecord(
            placeID: place.id,
            arrivalDate: now - 3_600,
            departureDate: now,
            timeZoneIdentifier: TimeZone.current.identifier,
            latitude: place.latitude,
            longitude: place.longitude,
            radiusMeters: place.radiusMeters,
            sourceRawValue: "inferred",
            quality: 0.9
        )
        container.mainContext.insert(visit)
        let trip = HistoryTripRecord(
            startedAt: now - 7_200,
            startTimeZoneIdentifier: TimeZone.current.identifier,
            originPlaceID: place.id
        )
        trip.endedAt = now - 3_600
        trip.destinationPlaceID = place.id
        trip.distanceMeters = 1_200
        trip.movingDuration = 1_800
        trip.elapsedDuration = 3_600
        trip.modeRawValue = MovementMode.walking.rawValue
        trip.modeConfidence = 0.8
        container.mainContext.insert(trip)
        let point = HistoryPoint(
            latitudeE5: 5_252_000,
            longitudeE5: 1_340_000,
            timestampSeconds: Int64((now - 7_200).timeIntervalSince1970),
            accuracyBucketMeters: 10,
            speedHalfMetersPerSecond: 4,
            courseFiveDegrees: 1,
            timeZoneIdentifier: TimeZone.current.identifier
        )
        container.mainContext.insert(try TrajectoryChunkRecord(tripID: trip.id, sequence: 0, points: [point]))
        let route = HistoryRoutePatternRecord(
            originPlaceID: place.id,
            destinationPlaceID: place.id,
            representativeGeometry: try HistoryPointCodec.encode([point]),
            lastUsedAt: now - 3_600
        )
        route.name = "Home Loop"
        route.isFavorite = true
        route.isManuallyEdited = true
        trip.routePatternID = route.id
        container.mainContext.insert(route)
        container.mainContext.insert(
            HistoryGapRecord(id: UUID(), startedAt: now - 900, endedAt: now - 600, reason: .unavailable)
        )
        container.mainContext.insert(
            PlaceSuggestionPreferenceRecord(placeID: place.id, dismissedSuggestionRawValue: PlaceLabelSuggestion.home.rawValue)
        )
        var mask = CoverageMask()
        mask.insert(localX: 3, localY: 4)
        container.mainContext.insert(
            CoverageChunkRecord(
                snapshot: CoverageChunkSnapshot(
                    key: CoverageChunkKey(x: 1, y: 1, zoom: ExplorationConfiguration.streetPrecise.chunkZoom),
                    mask: mask,
                    revision: 1
                )
            )
        )
        try container.mainContext.save()
        return (place.id, now)
    }

    private func emptyPayload(
        coverage: [BackupCoverageChunk] = [],
        visits: [BackupVisit] = []
    ) -> LockiBackupPayload {
        LockiBackupPayload(
            coverage: coverage,
            trajectory: [],
            trips: [],
            visits: visits,
            places: [],
            routes: [],
            gaps: [],
            suggestionPreferences: []
        )
    }

    private func backupPlace(id: UUID) -> BackupPlace {
        BackupPlace(
            id: id,
            latitude: 52.52,
            longitude: 13.40,
            radiusMeters: 35,
            name: "Home",
            category: nil,
            labelSourceRawValue: "local",
            isFavorite: false,
            isExcluded: false
        )
    }

    private func backupTrip(id: UUID, startedAt: Date, endedAt: Date?) -> BackupTrip {
        BackupTrip(
            id: id,
            startedAt: startedAt,
            endedAt: endedAt,
            startTimeZoneIdentifier: TimeZone.current.identifier,
            endTimeZoneIdentifier: nil,
            originPlaceID: nil,
            destinationPlaceID: nil,
            distanceMeters: 0,
            movingDuration: 0,
            elapsedDuration: 600,
            averageMovingSpeedMetersPerSecond: 0,
            peakSpeedMetersPerSecond: 0,
            modeRawValue: MovementMode.unknown.rawValue,
            modeConfidence: 0,
            completeness: 1,
            isExcluded: false,
            routePatternID: nil
        )
    }

    private func backupVisit(placeID: UUID, arrival: Date, departure: Date?) -> BackupVisit {
        BackupVisit(
            id: UUID(),
            placeID: placeID,
            arrivalDate: arrival,
            departureDate: departure,
            timeZoneIdentifier: TimeZone.current.identifier,
            latitude: 52.52,
            longitude: 13.40,
            radiusMeters: 35,
            sourceRawValue: "inferred",
            quality: 0.8,
            isExcluded: false
        )
    }
}
