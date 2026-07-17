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

    @MainActor
    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: ExploredTileRecord.self,
            CoverageChunkRecord.self,
            ExplorationSummaryRecord.self,
            configurations: configuration
        )
    }
}
