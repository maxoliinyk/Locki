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
}

enum LockiSchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)
    static var models: [any PersistentModel.Type] {
        LockiSchemaV2.models + [PlaceSuggestionPreferenceRecord.self]
    }
}

enum LockiSchemaMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [LockiSchemaV0.self, LockiSchemaV1.self, LockiSchemaV2.self, LockiSchemaV3.self]
    }

    static var stages: [MigrationStage] { [migrateV0toV1, migrateV1toV2, migrateV2toV3] }

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
}
