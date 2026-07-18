//
//  HistoryGapTests.swift
//  LockiTests
//
//  Created by Max Oliinyk on 18.07.2026.
//

import Foundation
import SwiftData
import Testing
@testable import Locki

@Suite("Actionable history gaps")
struct HistoryGapTests {
    private let startDate = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @Test("Temporary location failures persist only at the two-minute boundary")
    func unavailableDelayBoundary() {
        #expect(!HistoryGapCapturePolicy.persistsUnavailableGap(after: 119.999))
        #expect(HistoryGapCapturePolicy.persistsUnavailableGap(after: 120))
    }

    @Test("Discontinuity diagnosis distinguishes time gaps and jumps")
    func diagnosisTypes() {
        let filter = HistorySampleFilter()
        let first = historyPoint(longitude: 13.400, date: startDate)
        let delayed = historyPoint(longitude: 13.401, date: startDate + 601)
        let jumped = historyPoint(longitude: 14.400, date: startDate + 60)

        #expect(filter.discontinuityDiagnosis(from: first, to: delayed) == .prolongedUpdateInterval)
        #expect(filter.discontinuityDiagnosis(from: first, to: jumped) == .implausibleLocationJump)
    }

    @Test("Route repair eligibility enforces endpoint boundaries")
    func eligibilityBoundaries() {
        let engine = HistoryGapAssessmentEngine()
        let start = endpoint(longitude: 13.400, date: startDate)
        let nearby = endpoint(longitude: 13.400_5, date: startDate + 600)
        let routable = endpoint(longitude: 13.405, date: startDate + 600)

        let nearbyAssessment = engine.assess(
            reason: .discontinuity,
            startedAt: startDate,
            endedAt: startDate + 600,
            start: start,
            end: nearby,
            surroundingModes: []
        )
        let routableAssessment = engine.assess(
            reason: .discontinuity,
            startedAt: startDate,
            endedAt: startDate + 600,
            start: start,
            end: routable,
            surroundingModes: [.walking]
        )

        #expect(nearbyAssessment.routeIneligibility == .likelyNoMovement)
        #expect(routableAssessment.canRequestRoutes)
        #expect(routableAssessment.suggestedMode == .walking)
    }

    @Test("Long, distant, and non-movement gaps are not routed", arguments: [
        (HistoryGapReason.authorization, 600.0, HistoryGapRouteIneligibility.notDiscontinuity),
        (.discontinuity, 7_201.0, .tooLong),
    ])
    func rejectsUnreliableRepairs(
        reason: HistoryGapReason,
        duration: TimeInterval,
        expected: HistoryGapRouteIneligibility
    ) {
        let assessment = HistoryGapAssessmentEngine().assess(
            reason: reason,
            startedAt: startDate,
            endedAt: startDate + duration,
            start: endpoint(longitude: 13.4, date: startDate),
            end: endpoint(longitude: 13.41, date: startDate + duration),
            surroundingModes: []
        )
        #expect(assessment.routeIneligibility == expected)
    }

    @Test("Equivalent route candidates remain un-recommended")
    func ambiguousCandidatesHaveNoRecommendation() {
        let engine = HistoryGapAssessmentEngine()
        let first = GeoCoordinate(latitude: 52.52, longitude: 13.40)
        let last = GeoCoordinate(latitude: 52.52, longitude: 13.41)
        let candidates = [
            GapRouteCandidate(
                coordinates: [first, last],
                distanceMeters: 700,
                expectedTravelTime: 600,
                mode: .walking
            ),
            GapRouteCandidate(
                coordinates: [first, GeoCoordinate(latitude: 52.521, longitude: 13.405), last],
                distanceMeters: 705,
                expectedTravelTime: 605,
                mode: .walking
            ),
        ]

        let suggestions = engine.rankedSuggestions(
            candidates,
            gapDuration: 600,
            directDistanceMeters: 675
        )

        #expect(suggestions.count == 2)
        #expect(suggestions.allSatisfy { !$0.isRecommended })
    }

    @Test("Confirmed and dismissed gaps preserve measured statistics and export estimates")
    @MainActor
    func resolutionLifecycle() async throws {
        let container = try LockiPersistence.makeContainer(inMemory: true)
        let gapID = UUID()
        let first = historyPoint(longitude: 13.400, date: startDate)
        let last = historyPoint(longitude: 13.405, date: startDate + 600)
        let trip = HistoryTripRecord(startedAt: startDate, startTimeZoneIdentifier: "Europe/Berlin")
        trip.endedAt = startDate + 600
        trip.distanceMeters = 25
        container.mainContext.insert(trip)
        container.mainContext.insert(try TrajectoryChunkRecord(tripID: trip.id, sequence: 0, points: [first, last]))
        container.mainContext.insert(
            HistoryGapRecord(
                id: gapID,
                startedAt: startDate,
                endedAt: startDate + 600,
                reason: .discontinuity,
                diagnosis: .prolongedUpdateInterval
            )
        )
        try container.mainContext.save()
        let store = HistoryStore(modelContainer: container)
        let before = try await store.overview()
        let suggestion = GapRouteSuggestion(
            id: UUID(),
            coordinates: [first.coordinate, last.coordinate],
            distanceMeters: 350,
            expectedTravelTime: 500,
            mode: .walking,
            isRecommended: true
        )

        try await store.resolveGapRoute(id: gapID, suggestion: suggestion, at: startDate + 700)
        let after = try await store.overview()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(HistoryExport.self, from: try await store.exportJSON())
        let gap = try #require(export.gaps.first)
        let gpx = String(decoding: try await store.exportGPX(), as: UTF8.self)

        #expect(after.distanceMeters == before.distanceMeters)
        #expect(after.tripCount == before.tripCount)
        #expect(after.gapCount == before.gapCount)
        #expect(gap.resolution == .confirmedRoute)
        #expect(gap.estimatedRoute.count == 2)
        #expect(gpx.contains("<name>Estimated route</name>"))

        try await store.dismissGap(id: gapID)
        let dismissedValue = try await store.gapSnapshot(id: gapID)
        let dismissed = try #require(dismissedValue)
        #expect(dismissed.resolution == .dismissed)
        try await store.restoreGap(id: gapID)
        let restoredValue = try await store.gapSnapshot(id: gapID)
        let restored = try #require(restoredValue)
        #expect(restored.resolution == .unresolved)
    }

    @Test("Batch actions update only eligible gaps and preserve skipped route repairs")
    @MainActor
    func batchResolutionEligibility() async throws {
        let container = try LockiPersistence.makeContainer(inMemory: true)
        let movementID = UUID()
        let permissionID = UUID()
        let routeID = UUID()
        for gap in [
            HistoryGapRecord(
                id: movementID,
                startedAt: startDate,
                endedAt: startDate + 300,
                reason: .discontinuity
            ),
            HistoryGapRecord(
                id: permissionID,
                startedAt: startDate + 400,
                endedAt: startDate + 500,
                reason: .authorization
            ),
            HistoryGapRecord(
                id: routeID,
                startedAt: startDate + 600,
                endedAt: startDate + 900,
                reason: .discontinuity
            ),
        ] {
            container.mainContext.insert(gap)
        }
        try container.mainContext.save()
        let store = HistoryStore(modelContainer: container)
        let route = GapRouteSuggestion(
            id: UUID(),
            coordinates: [
                GeoCoordinate(latitude: 52.52, longitude: 13.4),
                GeoCoordinate(latitude: 52.52, longitude: 13.405),
            ],
            distanceMeters: 350,
            expectedTravelTime: 280,
            mode: .cycling,
            isRecommended: true
        )
        try await store.resolveGapRoute(id: routeID, suggestion: route)

        let selected = Set([movementID, permissionID, routeID])
        let noMovement = try await store.applyGapBatch(ids: selected, action: .noMovement)
        #expect(noMovement.appliedIDs == Set([movementID]))
        #expect(noMovement.skippedCount == 2)
        #expect((try await store.overview()).gapCount == 2)
        let preservedRoute = try #require(try await store.gapSnapshot(id: routeID))
        #expect(preservedRoute.resolution == .confirmedRoute)
        #expect(preservedRoute.estimatedRoute.count == 2)

        let dismissed = try await store.applyGapBatch(
            ids: [permissionID, routeID],
            action: .dismiss
        )
        #expect(dismissed.appliedIDs == Set([permissionID]))
        #expect(dismissed.skippedCount == 1)

        let restored = try await store.applyGapBatch(ids: selected, action: .restore)
        #expect(restored.appliedCount == 3)
        #expect((try await store.overview()).gapCount == 3)
        for id in selected {
            let snapshot = try #require(try await store.gapSnapshot(id: id))
            #expect(snapshot.resolution == .unresolved)
            #expect(snapshot.estimatedRoute.isEmpty)
        }
    }

    @Test("No-movement confirmation removes the interval from gaps and completeness")
    @MainActor
    func noMovementCompletesStationaryHistory() async throws {
        let container = try LockiPersistence.makeContainer(inMemory: true)
        let gapID = UUID()
        container.mainContext.insert(
            HistoryVisitRecord(
                placeID: nil,
                arrivalDate: startDate,
                departureDate: startDate + 1_200,
                timeZoneIdentifier: "Europe/Berlin",
                latitude: 52.52,
                longitude: 13.4,
                radiusMeters: 30,
                sourceRawValue: "inferred",
                quality: 1
            )
        )
        container.mainContext.insert(
            HistoryGapRecord(
                id: gapID,
                startedAt: startDate + 300,
                endedAt: startDate + 900,
                reason: .discontinuity
            )
        )
        try container.mainContext.save()
        let store = HistoryStore(modelContainer: container)

        try await store.resolveGapNoMovement(id: gapID)
        let resolvedOverview = try await store.overview()
        let resolvedSummary = try #require(
            container.mainContext.fetch(FetchDescriptor<HistoryDailySummaryRecord>()).first
        )
        #expect(resolvedOverview.gapCount == 0)
        #expect(resolvedSummary.gapDuration == 0)
        #expect(resolvedSummary.completeness == 1)

        try await store.restoreGap(id: gapID)
        let restoredOverview = try await store.overview()
        let restoredSummary = try #require(
            container.mainContext.fetch(FetchDescriptor<HistoryDailySummaryRecord>()).first
        )
        #expect(restoredOverview.gapCount == 1)
        #expect(restoredSummary.gapDuration == 600)
        #expect(restoredSummary.completeness < 1)
    }

    private func endpoint(longitude: Double, date: Date) -> HistoryGapEndpoint {
        HistoryGapEndpoint(
            coordinate: GeoCoordinate(latitude: 52.52, longitude: longitude),
            timestamp: date,
            accuracyMeters: 10,
            speedMetersPerSecond: nil,
            courseDegrees: nil
        )
    }

    private func historyPoint(longitude: Double, date: Date) -> HistoryPoint {
        HistoryPoint(
            latitudeE5: 5_252_000,
            longitudeE5: Int32((longitude * 100_000).rounded()),
            timestampSeconds: Int64(date.timeIntervalSince1970),
            accuracyBucketMeters: 10,
            speedHalfMetersPerSecond: nil,
            courseFiveDegrees: nil,
            timeZoneIdentifier: "Europe/Berlin"
        )
    }
}
