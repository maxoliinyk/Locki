//
//  LockiSchema.swift
//  Locki
//
//  Created by Max Oliinyk on 17.07.2026.
//

import Foundation
import SwiftData

// Exact snapshot of the first on-device SwiftData store. Keep these declarations
// immutable: staged migration identifies an unversioned store by its model checksum.
enum LockiSchemaV0: VersionedSchema {
    static let versionIdentifier = Schema.Version(0, 0, 0)
    static var models: [any PersistentModel.Type] {
        [ExploredTileRecord.self, CoverageChunkRecord.self, ExplorationSummaryRecord.self]
    }

    @Model
    final class ExploredTileRecord {
        var key: String
        var zoom: Int
        var x: Int
        var y: Int
        var firstUnlockedAt: Date
        var lastUnlockedAt: Date
        var unlockCount: Int

        init(
            key: String,
            zoom: Int,
            x: Int,
            y: Int,
            firstUnlockedAt: Date,
            lastUnlockedAt: Date,
            unlockCount: Int
        ) {
            self.key = key
            self.zoom = zoom
            self.x = x
            self.y = y
            self.firstUnlockedAt = firstUnlockedAt
            self.lastUnlockedAt = lastUnlockedAt
            self.unlockCount = unlockCount
        }
    }

    @Model
    final class CoverageChunkRecord {
        @Attribute(.unique) var key: String
        var zoom: Int
        var x: Int
        var y: Int
        var maskData: Data
        var exploredCellCount: Int
        var revision: Int

        init(
            key: String,
            zoom: Int,
            x: Int,
            y: Int,
            maskData: Data,
            exploredCellCount: Int,
            revision: Int
        ) {
            self.key = key
            self.zoom = zoom
            self.x = x
            self.y = y
            self.maskData = maskData
            self.exploredCellCount = exploredCellCount
            self.revision = revision
        }
    }

    @Model
    final class ExplorationSummaryRecord {
        @Attribute(.unique) var key: String
        var exploredCellCount: Int
        var lastUnlockDate: Date?
        var migrationVersion: Int

        init(
            key: String,
            exploredCellCount: Int,
            lastUnlockDate: Date?,
            migrationVersion: Int
        ) {
            self.key = key
            self.exploredCellCount = exploredCellCount
            self.lastUnlockDate = lastUnlockDate
            self.migrationVersion = migrationVersion
        }
    }
}

enum LockiSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            ExploredTileRecord.self,
            CoverageChunkRecord.self,
            ExplorationSummaryRecord.self,
            PendingPathAnchorRecord.self,
        ]
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

        init(
            id: UUID,
            cellX: Int,
            cellY: Int,
            cellZoom: Int,
            observedAt: Date,
            accuracyBucketMeters: Int,
            speedBucketMetersPerSecond: Int?,
            courseBucketDegrees: Int?,
            attemptCount: Int,
            lastAttemptAt: Date?
        ) {
            self.id = id
            self.cellX = cellX
            self.cellY = cellY
            self.cellZoom = cellZoom
            self.observedAt = observedAt
            self.accuracyBucketMeters = accuracyBucketMeters
            self.speedBucketMetersPerSecond = speedBucketMetersPerSecond
            self.courseBucketDegrees = courseBucketDegrees
            self.attemptCount = attemptCount
            self.lastAttemptAt = lastAttemptAt
        }
    }
}

enum LockiSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] {
        LockiSchemaV1.models + [
            HistoryMetadataRecord.self,
            TrajectoryChunkRecord.self,
            HistoryTripRecord.self,
            HistoryVisitRecord.self,
            HistoryPlaceRecord.self,
            HistoryRoutePatternRecord.self,
            HistoryDailySummaryRecord.self,
            HistoryGapRecord.self,
        ]
    }

    @Model
    final class HistoryGapRecord {
        @Attribute(.unique) var id: UUID
        var startedAt: Date
        var endedAt: Date?
        var reasonRawValue: String

        init(id: UUID, startedAt: Date, endedAt: Date?, reasonRawValue: String) {
            self.id = id
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.reasonRawValue = reasonRawValue
        }
    }
}

enum LockiSchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)
    static var models: [any PersistentModel.Type] {
        LockiSchemaV2.models + [PlaceSuggestionPreferenceRecord.self]
    }
}

enum LockiSchemaV4: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)
    static var models: [any PersistentModel.Type] {
        LockiSchemaV3.models.filter { $0 != LockiSchemaV1.PendingPathAnchorRecord.self }
            + [PendingPathAnchorRecord.self]
    }
}

enum LockiSchemaV5: VersionedSchema {
    static let versionIdentifier = Schema.Version(5, 0, 0)
    static var models: [any PersistentModel.Type] {
        LockiSchemaV4.models.filter { $0 != LockiSchemaV2.HistoryGapRecord.self }
            + [HistoryGapRecord.self]
    }
}

enum LockiSchemaMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [
            LockiSchemaV0.self,
            LockiSchemaV1.self,
            LockiSchemaV2.self,
            LockiSchemaV3.self,
            LockiSchemaV4.self,
            LockiSchemaV5.self,
        ]
    }

    static var stages: [MigrationStage] {
        [migrateV0toV1, migrateV1toV2, migrateV2toV3, migrateV3toV4, migrateV4toV5]
    }

    static let migrateV0toV1 = MigrationStage.lightweight(
        fromVersion: LockiSchemaV0.self,
        toVersion: LockiSchemaV1.self
    )

    static let migrateV1toV2 = MigrationStage.lightweight(
        fromVersion: LockiSchemaV1.self,
        toVersion: LockiSchemaV2.self
    )

    static let migrateV2toV3 = MigrationStage.lightweight(
        fromVersion: LockiSchemaV2.self,
        toVersion: LockiSchemaV3.self
    )

    static let migrateV3toV4 = MigrationStage.lightweight(
        fromVersion: LockiSchemaV3.self,
        toVersion: LockiSchemaV4.self
    )

    static let migrateV4toV5 = MigrationStage.lightweight(
        fromVersion: LockiSchemaV4.self,
        toVersion: LockiSchemaV5.self
    )
}
