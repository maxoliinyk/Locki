//
//  CoverageStore.swift
//  Locki
//
//  Created by Max Oliinyk on 17.07.2026.
//

import Foundation
import SwiftData

@ModelActor
actor CoverageStore {
    private static let currentMigrationVersion = 1

    func prepare() throws -> CoverageSnapshot {
        try migrateLegacyTilesIfNeeded()
        return try snapshot()
    }

    func merge(_ delta: CoverageDelta) throws -> CoverageSnapshot {
        guard !delta.isEmpty else { return try snapshot() }

        let summary = try fetchOrCreateSummary()
        var addedTotal = 0

        for (key, mask) in delta.chunks where !mask.isEmpty {
            if let record = try record(for: key.rawValue) {
                addedTotal += record.merge(mask)
            } else {
                let chunk = CoverageChunkSnapshot(key: key, mask: mask, revision: 1)
                modelContext.insert(CoverageChunkRecord(snapshot: chunk))
                addedTotal += mask.setBitCount
            }
        }

        if addedTotal > 0 {
            summary.exploredCellCount += addedTotal
            summary.lastUnlockDate = max(summary.lastUnlockDate ?? .distantPast, delta.unlockedAt)
            try modelContext.save()
        }

        return try snapshot()
    }

    func snapshot() throws -> CoverageSnapshot {
        let chunks = try modelContext.fetch(FetchDescriptor<CoverageChunkRecord>())
        let summary = try fetchOrCreateSummary()
        let snapshots = Dictionary(uniqueKeysWithValues: chunks.map { ($0.snapshot.key, $0.snapshot) })

        return CoverageSnapshot(
            chunks: snapshots,
            totalExploredCellCount: summary.exploredCellCount,
            lastUnlockDate: summary.lastUnlockDate,
            generation: chunks.reduce(0) { $0 &+ $1.revision }
        )
    }

    func summary() throws -> ExplorationSummary {
        let record = try fetchOrCreateSummary()
        return ExplorationSummary(
            exploredCellCount: record.exploredCellCount,
            lastUnlockDate: record.lastUnlockDate
        )
    }

    func flush() throws {
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    private func migrateLegacyTilesIfNeeded() throws {
        let summary = try fetchOrCreateSummary()
        guard summary.migrationVersion < Self.currentMigrationVersion else { return }

        let legacyRecords = try modelContext.fetch(FetchDescriptor<ExploredTileRecord>())
        var migrationDelta = CoverageDelta(unlockedAt: .distantPast)

        for record in legacyRecords where record.zoom == 18 {
            migrationDelta.unlockedAt = max(migrationDelta.unlockedAt, record.lastUnlockedAt)
            let scale = 1 << (ExplorationConfiguration.streetPrecise.coverageZoom - record.zoom)
            for x in (record.x * scale)..<((record.x + 1) * scale) {
                for y in (record.y * scale)..<((record.y + 1) * scale) {
                    migrationDelta.insert(
                        CoverageCell(x: x, y: y, zoom: ExplorationConfiguration.streetPrecise.coverageZoom)
                    )
                }
            }
        }

        var addedTotal = 0
        for (key, mask) in migrationDelta.chunks where !mask.isEmpty {
            if let record = try record(for: key.rawValue) {
                addedTotal += record.merge(mask)
            } else {
                let chunk = CoverageChunkSnapshot(key: key, mask: mask, revision: 1)
                modelContext.insert(CoverageChunkRecord(snapshot: chunk))
                addedTotal += mask.setBitCount
            }
        }

        summary.exploredCellCount += addedTotal
        if migrationDelta.unlockedAt != .distantPast {
            summary.lastUnlockDate = max(summary.lastUnlockDate ?? .distantPast, migrationDelta.unlockedAt)
        }
        summary.migrationVersion = Self.currentMigrationVersion
        legacyRecords.forEach(modelContext.delete)
        try modelContext.save()
    }

    private func fetchOrCreateSummary() throws -> ExplorationSummaryRecord {
        var descriptor = FetchDescriptor<ExplorationSummaryRecord>(
            predicate: #Predicate { $0.key == "primary" }
        )
        descriptor.fetchLimit = 1
        if let summary = try modelContext.fetch(descriptor).first {
            return summary
        }

        let summary = ExplorationSummaryRecord()
        modelContext.insert(summary)
        return summary
    }

    private func record(for key: String) throws -> CoverageChunkRecord? {
        var descriptor = FetchDescriptor<CoverageChunkRecord>(
            predicate: #Predicate { $0.key == key }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}

nonisolated struct ExplorationSummary: Hashable, Sendable {
    let exploredCellCount: Int
    let lastUnlockDate: Date?
}
