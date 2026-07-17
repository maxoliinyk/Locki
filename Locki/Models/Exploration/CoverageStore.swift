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
        let addedTotal = try mergeCoverage(delta)

        if addedTotal > 0 {
            summary.exploredCellCount += addedTotal
            summary.lastUnlockDate = max(summary.lastUnlockDate ?? .distantPast, delta.unlockedAt)
            try modelContext.save()
        }

        return try snapshot()
    }

    func enqueuePathAnchor(
        _ anchor: PathAnchor,
        now: Date = .now,
        configuration: PathMatchingConfiguration = .standard
    ) throws -> [PathAnchor] {
        guard anchor.cell.zoom == ExplorationConfiguration.streetPrecise.coverageZoom else {
            return try pendingPathAnchors(now: now, configuration: configuration)
        }
        let cellLimit = 1 << anchor.cell.zoom
        guard (0..<cellLimit).contains(anchor.cell.x),
              (0..<cellLimit).contains(anchor.cell.y),
              (0...Int(ExplorationConfiguration.streetPrecise.maximumHorizontalAccuracyMeters)).contains(anchor.accuracyBucketMeters),
              anchor.speedBucketMetersPerSecond.map({ (0...Int(configuration.maximumSpeedMetersPerSecond)).contains($0) }) ?? true,
              anchor.courseBucketDegrees.map({ (0..<360).contains($0) }) ?? true else {
            return try pendingPathAnchors(now: now, configuration: configuration)
        }
        try purgeExpiredPathAnchors(now: now, configuration: configuration)
        let records = try pathAnchorRecords()
        if records.last?.cellX != anchor.cell.x || records.last?.cellY != anchor.cell.y {
            modelContext.insert(PendingPathAnchorRecord(anchor: anchor))
            try modelContext.save()
        }
        return try pathAnchorRecords().map(\.anchor)
    }

    func pendingPathAnchors(
        now: Date = .now,
        configuration: PathMatchingConfiguration = .standard
    ) throws -> [PathAnchor] {
        try purgeExpiredPathAnchors(now: now, configuration: configuration)
        return try pathAnchorRecords().map(\.anchor)
    }

    func beginPathMatchAttempt(
        terminalAnchorID: UUID,
        now: Date = .now,
        configuration: PathMatchingConfiguration = .standard
    ) throws -> Bool {
        guard let record = try pathAnchorRecords().first(where: { $0.id == terminalAnchorID }),
              record.attemptCount < configuration.maximumAttempts else {
            return false
        }
        if let lastAttemptAt = record.lastAttemptAt,
           now.timeIntervalSince(lastAttemptAt) < configuration.retryInterval {
            return false
        }
        record.attemptCount += 1
        record.lastAttemptAt = now
        try modelContext.save()
        return true
    }

    func commitMatchedPath(
        _ delta: CoverageDelta,
        consuming anchorIDs: Set<UUID>,
        retaining seedID: UUID?
    ) throws -> PathMatchCommitResult {
        do {
            let summary = try fetchOrCreateSummary()
            let addedCount = try mergeCoverage(delta)
            for record in try pathAnchorRecords()
            where anchorIDs.contains(record.id) && record.id != seedID {
                modelContext.delete(record)
            }
            summary.matchedPathCount += 1
            if addedCount > 0 {
                summary.exploredCellCount += addedCount
                summary.lastUnlockDate = max(summary.lastUnlockDate ?? .distantPast, delta.unlockedAt)
            }
            try modelContext.save()
            return PathMatchCommitResult(
                addedCellCount: addedCount,
                matchedPathCount: summary.matchedPathCount,
                pendingAnchorCount: try pathAnchorRecords().count
            )
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func purgePendingPathAnchors() throws {
        try pathAnchorRecords().forEach(modelContext.delete)
        try modelContext.save()
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
            lastUnlockDate: record.lastUnlockDate,
            matchedPathCount: record.matchedPathCount
        )
    }

    func flush() throws {
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func reset() throws -> CoverageSnapshot {
        try modelContext.delete(model: CoverageChunkRecord.self)
        try modelContext.delete(model: ExploredTileRecord.self)
        try modelContext.delete(model: PendingPathAnchorRecord.self)
        try modelContext.delete(model: ExplorationSummaryRecord.self)
        try modelContext.save()
        let empty = try snapshot()
        try modelContext.save()
        return empty
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

    private func mergeCoverage(_ delta: CoverageDelta) throws -> Int {
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
        return addedTotal
    }

    private func pathAnchorRecords() throws -> [PendingPathAnchorRecord] {
        try modelContext.fetch(
            FetchDescriptor<PendingPathAnchorRecord>(
                sortBy: [SortDescriptor(\.observedAt)]
            )
        )
    }

    private func purgeExpiredPathAnchors(
        now: Date,
        configuration: PathMatchingConfiguration
    ) throws {
        var changed = false
        for record in try pathAnchorRecords() {
            let age = now.timeIntervalSince(record.observedAt)
            if age < -configuration.futureTimestampTolerance || age > configuration.retentionInterval {
                modelContext.delete(record)
                changed = true
            }
        }
        if changed { try modelContext.save() }
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
    let matchedPathCount: Int
}

nonisolated struct PathMatchCommitResult: Hashable, Sendable {
    let addedCellCount: Int
    let matchedPathCount: Int
    let pendingAnchorCount: Int
}
