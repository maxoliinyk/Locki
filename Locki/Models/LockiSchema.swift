//
//  LockiSchema.swift
//  Locki
//
//  Created by Max Oliinyk on 17.07.2026.
//

import SwiftData

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
    static var schemas: [any VersionedSchema.Type] { [LockiSchemaV1.self, LockiSchemaV2.self, LockiSchemaV3.self] }
    static var stages: [MigrationStage] { [migrateV1toV2, migrateV2toV3] }

    static let migrateV1toV2 = MigrationStage.lightweight(
        fromVersion: LockiSchemaV1.self,
        toVersion: LockiSchemaV2.self
    )

    static let migrateV2toV3 = MigrationStage.lightweight(
        fromVersion: LockiSchemaV2.self,
        toVersion: LockiSchemaV3.self
    )
}
