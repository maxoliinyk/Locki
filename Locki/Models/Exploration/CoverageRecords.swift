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

    init(
        key: String = "primary",
        exploredCellCount: Int = 0,
        lastUnlockDate: Date? = nil,
        migrationVersion: Int = 0
    ) {
        self.key = key
        self.exploredCellCount = exploredCellCount
        self.lastUnlockDate = lastUnlockDate
        self.migrationVersion = migrationVersion
    }
}
