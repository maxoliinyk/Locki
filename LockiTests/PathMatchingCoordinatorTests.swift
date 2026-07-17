//
//  PathMatchingCoordinatorTests.swift
//  LockiTests
//
//  Created by Max Oliinyk on 17.07.2026.
//

import Foundation
import SwiftData
import Testing
@testable import Locki

@Suite("Path matching coordinator", .serialized)
@MainActor
struct PathMatchingCoordinatorTests {
    @Test("Ambiguous endpoint routes fall back to bounded stitched legs")
    func adaptiveFallbackCommitsCoverage() async throws {
        let container = try makeContainer()
        let store = CoverageStore(modelContainer: container)
        let now = Date(timeIntervalSinceReferenceDate: 80_000)
        let sessionID = UUID()
        let anchors = (0..<6).map { index in
            PathAnchor(
                cell: CoverageCell.containing(
                    GeoCoordinate(latitude: 52.52, longitude: 13.405 + Double(index) * 0.005),
                    zoom: 21
                ),
                observedAt: now + Double(index) * 300,
                accuracyBucketMeters: 10,
                speedBucketMetersPerSecond: 6,
                courseBucketDegrees: 90,
                source: .significantChange,
                motionKind: .cycling,
                sessionID: sessionID
            )
        }
        for anchor in anchors {
            _ = try await store.enqueuePathAnchor(anchor, now: anchor.observedAt)
        }

        let provider = AdaptiveRouteProvider()
        var committed = false
        let coordinator = PathMatchingCoordinator(
            store: store,
            routeProvider: provider,
            coverageHandler: { _, _ in committed = true },
            statusHandler: { _, _ in },
            persistenceIssueHandler: { _ in }
        )

        let result = await coordinator.processPending(now: now + 1_501, deadline: .now + 60)
        let summary = try await store.summary()

        #expect(result == .matched)
        #expect(committed)
        #expect(summary.matchedPathCount == 1)
        #expect(provider.requests.count <= 4)
    }

    @Test("Expired execution deadline avoids route requests")
    func deadlineStopsProcessing() async throws {
        let container = try makeContainer()
        let provider = AdaptiveRouteProvider()
        let coordinator = PathMatchingCoordinator(
            store: CoverageStore(modelContainer: container),
            routeProvider: provider,
            coverageHandler: { _, _ in },
            statusHandler: { _, _ in },
            persistenceIssueHandler: { _ in }
        )

        let result = await coordinator.processPending(deadline: .distantPast)

        #expect(result == .deferred(.cancelled))
        #expect(provider.requests.isEmpty)
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: ExploredTileRecord.self,
            CoverageChunkRecord.self,
            ExplorationSummaryRecord.self,
            PendingPathAnchorRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }
}

@MainActor
private final class AdaptiveRouteProvider: PathRouteProviding {
    private(set) var requests: [PathRouteRequest] = []

    func routes(for request: PathRouteRequest) async throws -> [PathRouteCandidate] {
        requests.append(request)
        if requests.count == 1 {
            return [offsetCandidate(request, meters: 22), offsetCandidate(request, meters: -22)]
        }
        return [candidate(request)]
    }

    private func candidate(_ request: PathRouteRequest) -> PathRouteCandidate {
        PathRouteCandidate(
            coordinates: [request.source, request.destination],
            distanceMeters: request.source.distance(to: request.destination),
            expectedTravelTime: 300,
            mode: request.modes.first ?? .cycling
        )
    }

    private func offsetCandidate(_ request: PathRouteRequest, meters: Double) -> PathRouteCandidate {
        let offset = meters / 111_320
        let source = GeoCoordinate(
            latitude: request.source.latitude + offset,
            longitude: request.source.longitude
        )
        let destination = GeoCoordinate(
            latitude: request.destination.latitude + offset,
            longitude: request.destination.longitude
        )
        return PathRouteCandidate(
            coordinates: [source, destination],
            distanceMeters: source.distance(to: destination),
            expectedTravelTime: 1_500,
            mode: request.modes.first ?? .cycling
        )
    }
}
