//
//  CoverageStoreTests.swift
//  LockiTests
//
//  Created by Max Oliinyk on 17.07.2026.
//

import Foundation
import SwiftData
import Testing
@testable import Locki

@Suite("Coverage persistence", .serialized)
struct CoverageStoreTests {
    @Test("Repeated coverage merges are idempotent")
    @MainActor
    func repeatedMergeIsIdempotent() async throws {
        let container = try makeContainer()
        let store = CoverageStore(modelContainer: container)
        var delta = CoverageDelta(unlockedAt: .now)
        delta.insert(CoverageCell(x: 100, y: 200, zoom: 21))

        let first = try await store.merge(delta)
        let second = try await store.merge(delta)

        #expect(first.totalExploredCellCount == 1)
        #expect(second.totalExploredCellCount == 1)
    }

    @Test("Legacy zoom 18 tiles migrate to 64 zoom 21 cells")
    @MainActor
    func migratesLegacyTile() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(
            ExploredTileRecord(
                tile: ExplorationTile(x: 100, y: 200, zoom: 18),
                unlockedAt: Date(timeIntervalSinceReferenceDate: 1_000)
            )
        )
        try context.save()

        let store = CoverageStore(modelContainer: container)
        let snapshot = try await store.prepare()
        let legacyCount = try context.fetchCount(FetchDescriptor<ExploredTileRecord>())

        #expect(snapshot.totalExploredCellCount == 64)
        #expect(snapshot.chunks.values.reduce(0) { $0 + $1.mask.setBitCount } == 64)
        #expect(legacyCount == 0)
    }

    @Test("Pending path anchors expire and attempts are throttled")
    @MainActor
    func pathAnchorExpiryAndThrottle() async throws {
        let container = try makeContainer()
        let store = CoverageStore(modelContainer: container)
        let now = Date(timeIntervalSinceReferenceDate: 30_000)
        let anchor = makeAnchor(time: now)

        _ = try await store.enqueuePathAnchor(anchor, now: now)
        let firstAttempt = try await store.beginPathMatchAttempt(terminalAnchorID: anchor.id, now: now)
        let immediateRetry = try await store.beginPathMatchAttempt(
            terminalAnchorID: anchor.id,
            now: now.addingTimeInterval(60)
        )
        try await store.recordPathMatchFailure(
            terminalAnchorID: anchor.id,
            failure: .routeUnavailable,
            now: now
        )
        let beforeRetryDate = try await store.beginPathMatchAttempt(
            terminalAnchorID: anchor.id,
            now: now.addingTimeInterval(14 * 60)
        )
        let expired = try await store.pendingPathAnchors(now: now.addingTimeInterval(6 * 60 * 60 + 1))

        #expect(firstAttempt)
        #expect(!immediateRetry)
        #expect(!beforeRetryDate)
        #expect(expired.isEmpty)
    }

    @Test("Path matching stops after the configured attempt limit")
    @MainActor
    func pathMatchingAttemptLimit() async throws {
        let container = try makeContainer()
        let store = CoverageStore(modelContainer: container)
        let now = Date(timeIntervalSinceReferenceDate: 35_000)
        let anchor = makeAnchor(time: now)
        _ = try await store.enqueuePathAnchor(anchor, now: now)

        for attempt in 0..<PathMatchingConfiguration.standard.maximumAttempts {
            let attemptTime = now.addingTimeInterval(Double(attempt) * 15 * 60)
            #expect(try await store.beginPathMatchAttempt(terminalAnchorID: anchor.id, now: attemptTime))
        }
        let rejected = try await store.beginPathMatchAttempt(
            terminalAnchorID: anchor.id,
            now: now.addingTimeInterval(6 * 15 * 60)
        )
        #expect(!rejected)
    }

    @Test("Matched path commit consumes anchors except its continuation seed")
    @MainActor
    func matchedPathCommitIsAtomic() async throws {
        let container = try makeContainer()
        let store = CoverageStore(modelContainer: container)
        let now = Date(timeIntervalSinceReferenceDate: 40_000)
        let first = makeAnchor(xOffset: 0, time: now)
        let middle = makeAnchor(xOffset: 40, time: now.addingTimeInterval(300))
        let last = makeAnchor(xOffset: 80, time: now.addingTimeInterval(600))
        for anchor in [first, middle, last] {
            _ = try await store.enqueuePathAnchor(anchor, now: anchor.observedAt)
        }
        var delta = CoverageDelta(unlockedAt: last.observedAt)
        delta.insert(first.cell)
        delta.insert(middle.cell)
        delta.insert(last.cell)

        let result = try await store.commitMatchedPath(
            delta,
            consuming: Set([first.id, middle.id, last.id]),
            retaining: last.id
        )
        let remaining = try await store.pendingPathAnchors(now: last.observedAt)
        let summary = try await store.summary()

        #expect(result.addedCellCount == 3)
        #expect(result.pendingAnchorCount == 1)
        #expect(remaining.map(\.id) == [last.id])
        #expect(summary.matchedPathCount == 1)
        #expect(summary.exploredCellCount == 3)
    }

    @MainActor
    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: ExploredTileRecord.self,
            CoverageChunkRecord.self,
            ExplorationSummaryRecord.self,
            PendingPathAnchorRecord.self,
            configurations: configuration
        )
    }

    private func makeAnchor(xOffset: Int = 0, time: Date) -> PathAnchor {
        let origin = CoverageCell.containing(
            GeoCoordinate(latitude: 52.52, longitude: 13.405),
            zoom: ExplorationConfiguration.streetPrecise.coverageZoom
        )
        return PathAnchor(
            cell: CoverageCell(x: origin.x + xOffset, y: origin.y, zoom: origin.zoom),
            observedAt: time,
            accuracyBucketMeters: 10,
            speedBucketMetersPerSecond: 6,
            courseBucketDegrees: 90
        )
    }
}
