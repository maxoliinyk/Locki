//
//  CoverageRecords.swift
//  Locki
//
//  Created by Max Oliinyk on 17.07.2026.
//

import Foundation
import SwiftData

@Model
final class CoverageChunkRecord {
    @Attribute(.unique) var key: String
    var zoom: Int
    var x: Int
    var y: Int
    var maskData: Data
    var exploredCellCount: Int
    var revision: Int

    init(snapshot: CoverageChunkSnapshot) {
        key = snapshot.key.rawValue
        zoom = snapshot.key.zoom
        x = snapshot.key.x
        y = snapshot.key.y
        maskData = snapshot.mask.data
        exploredCellCount = snapshot.mask.setBitCount
        revision = snapshot.revision
    }

    var snapshot: CoverageChunkSnapshot {
        CoverageChunkSnapshot(
            key: CoverageChunkKey(x: x, y: y, zoom: zoom),
            mask: CoverageMask(data: maskData),
            revision: revision
        )
    }

    func merge(_ mask: CoverageMask) -> Int {
        var current = CoverageMask(data: maskData)
        let added = current.formUnion(mask)
        guard added > 0 else { return 0 }
        maskData = current.data
        exploredCellCount += added
        revision += 1
        return added
    }
}

@Model
final class ExplorationSummaryRecord {
    @Attribute(.unique) var key: String
    var exploredCellCount: Int
    var lastUnlockDate: Date?
    var migrationVersion: Int
    var matchedPathCount: Int = 0

    init(
        key: String = "primary",
        exploredCellCount: Int = 0,
        lastUnlockDate: Date? = nil,
        migrationVersion: Int = 0,
        matchedPathCount: Int = 0
    ) {
        self.key = key
        self.exploredCellCount = exploredCellCount
        self.lastUnlockDate = lastUnlockDate
        self.migrationVersion = migrationVersion
        self.matchedPathCount = matchedPathCount
    }
}

@Model
final class PendingPathAnchorRecord {
    @Attribute(.unique) var id: UUID
    var cellX: Int
    var cellY: Int
    var cellZoom: Int
    var observedAt: Date
    var accuracyBucketMeters: Int
    var speedBucketMetersPerSecond: Int?
    var courseBucketDegrees: Int?
    var attemptCount: Int
    var lastAttemptAt: Date?

    init(anchor: PathAnchor) {
        id = anchor.id
        cellX = anchor.cell.x
        cellY = anchor.cell.y
        cellZoom = anchor.cell.zoom
        observedAt = anchor.observedAt
        accuracyBucketMeters = anchor.accuracyBucketMeters
        speedBucketMetersPerSecond = anchor.speedBucketMetersPerSecond
        courseBucketDegrees = anchor.courseBucketDegrees
        attemptCount = 0
        lastAttemptAt = nil
    }

    var anchor: PathAnchor {
        PathAnchor(
            id: id,
            cell: CoverageCell(x: cellX, y: cellY, zoom: cellZoom),
            observedAt: observedAt,
            accuracyBucketMeters: accuracyBucketMeters,
            speedBucketMetersPerSecond: speedBucketMetersPerSecond,
            courseBucketDegrees: courseBucketDegrees
        )
    }
}
