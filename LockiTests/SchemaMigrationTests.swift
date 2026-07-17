//
//  SchemaMigrationTests.swift
//  LockiTests
//
//  Created by Max Oliinyk on 17.07.2026.
//

import Foundation
import SwiftData
import Testing
@testable import Locki

@Suite("Schema migration", .serialized)
struct SchemaMigrationTests {
    @Test("The first unversioned exploration store migrates without data loss")
    @MainActor
    func firstExplorationStoreMigrates() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "LockiMigration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "default.store")
        let date = Date(timeIntervalSinceReferenceDate: 900_000)

        try createLegacyStore(at: storeURL, date: date)

        let migrated = try ModelContainer(
            for: Schema(versionedSchema: LockiSchemaV3.self),
            migrationPlan: LockiSchemaMigrationPlan.self,
            configurations: ModelConfiguration(url: storeURL)
        )
        let summaries = try migrated.mainContext.fetch(FetchDescriptor<ExplorationSummaryRecord>())
        let tiles = try migrated.mainContext.fetch(FetchDescriptor<ExploredTileRecord>())
        let chunks = try migrated.mainContext.fetch(FetchDescriptor<CoverageChunkRecord>())
        let summary = try #require(summaries.first)
        let tile = try #require(tiles.first)
        let chunk = try #require(chunks.first)

        #expect(summary.exploredCellCount == 7)
        #expect(summary.matchedPathCount == 0)
        #expect(tile.key == "18/1/2")
        #expect(tile.unlockCount == 3)
        #expect(chunk.key == "18/4/5")
        #expect(chunk.maskData == Data([0xA5]))
        #expect(chunk.revision == 2)
    }

    @MainActor
    private func createLegacyStore(at storeURL: URL, date: Date) throws {
        let legacySchema = Schema(LockiSchemaV0.models)
        let container = try ModelContainer(
            for: legacySchema,
            configurations: ModelConfiguration(url: storeURL)
        )
        container.mainContext.insert(
            LockiSchemaV0.ExplorationSummaryRecord(
                key: "primary",
                exploredCellCount: 7,
                lastUnlockDate: date,
                migrationVersion: 1
            )
        )
        container.mainContext.insert(
            LockiSchemaV0.ExploredTileRecord(
                key: "18/1/2",
                zoom: 18,
                x: 1,
                y: 2,
                firstUnlockedAt: date,
                lastUnlockedAt: date + 60,
                unlockCount: 3
            )
        )
        container.mainContext.insert(
            LockiSchemaV0.CoverageChunkRecord(
                key: "18/4/5",
                zoom: 18,
                x: 4,
                y: 5,
                maskData: Data([0xA5]),
                exploredCellCount: 4,
                revision: 2
            )
        )
        try container.mainContext.save()
    }
}
