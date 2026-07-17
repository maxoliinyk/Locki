//
//  TrackingServicesTests.swift
//  LockiTests
//
//  Created by Max Oliinyk on 17.07.2026.
//

import Foundation
import Testing
@testable import Locki

@Suite("Adaptive passive tracking")
struct TrackingServicesTests {
    @Test("Legacy continuous preference migrates without changing an explicit mode")
    func trackingModeMigration() {
        #expect(LocationTrackingService.resolvedTrackingMode(storedMode: nil, legacyContinuous: false) == .efficient)
        #expect(LocationTrackingService.resolvedTrackingMode(storedMode: nil, legacyContinuous: true) == .detailed)
        #expect(LocationTrackingService.resolvedTrackingMode(storedMode: "efficient", legacyContinuous: true) == .efficient)
        #expect(LocationTrackingService.resolvedTrackingMode(storedMode: "detailed", legacyContinuous: false) == .detailed)
    }

    @Test("Background refresh uses a coarse best-effort cadence")
    func backgroundRefreshPolicy() {
        #expect(BackgroundRefreshPolicy.earliestDelay == 1_800)
        #expect(BackgroundRefreshPolicy.shouldSchedule(historyEnabled: true))
        #expect(!BackgroundRefreshPolicy.shouldSchedule(historyEnabled: false))
    }

    @Test("Monitor allocation reserves capacity and removes overlapping lower-ranked places")
    @MainActor
    func monitorSelection() {
        let candidate = monitoredCandidate(id: nil, longitude: 13.4, candidate: true)
        let favorite = monitoredCandidate(id: UUID(), longitude: 13.41, favorite: true)
        let overlapping = monitoredCandidate(id: UUID(), longitude: 13.4101, visits: 100)
        let remaining = (0..<30).map {
            monitoredCandidate(id: UUID(), longitude: 13.5 + Double($0) * 0.01, visits: 30 - $0)
        }

        let selected = PlaceMonitorService.selectedCandidates(
            from: [overlapping, favorite, candidate] + remaining
        )
        #expect(selected.count == 16)
        #expect(selected.first?.isCandidate == true)
        #expect(selected.contains { $0.placeID == favorite.placeID })
        #expect(!selected.contains { $0.placeID == overlapping.placeID })
    }

    @Test("Provisional stay remains hidden until three minutes and credible evidence")
    func provisionalVisibility() {
        let start = Date(timeIntervalSinceReferenceDate: 50_000)
        let weak = ProvisionalStaySnapshot(
            startedAt: start,
            placeID: nil,
            placeName: nil,
            evidenceCount: 1,
            hasStationaryMotion: false
        )
        let corroborated = ProvisionalStaySnapshot(
            startedAt: start,
            placeID: nil,
            placeName: nil,
            evidenceCount: 2,
            hasStationaryMotion: false
        )
        #expect(!weak.isCredible(at: start + 600))
        #expect(!corroborated.isCredible(at: start + 179))
        #expect(corroborated.isCredible(at: start + 180))
    }

    private func monitoredCandidate(
        id: UUID?,
        longitude: Double,
        candidate: Bool = false,
        favorite: Bool = false,
        visits: Int = 1
    ) -> MonitoredPlaceCandidate {
        MonitoredPlaceCandidate(
            placeID: id,
            coordinate: GeoCoordinate(latitude: 52.52, longitude: longitude),
            radiusMeters: 100,
            isCandidate: candidate,
            isFavorite: favorite,
            isUserNamed: false,
            visitCount: visits,
            totalDuration: Double(visits) * 600,
            lastVisitAt: .now
        )
    }
}
