//
//  ExploredTileRecord.swift
//  Locki
//
//  Created by Max Oliinyk on 06.05.2026.
//

import Foundation
import SwiftData

@Model
final class ExploredTileRecord {
    var key: String
    var zoom: Int
    var x: Int
    var y: Int
    var firstUnlockedAt: Date
    var lastUnlockedAt: Date
    var unlockCount: Int

    init(tile: ExplorationTile, unlockedAt: Date) {
        key = tile.key
        zoom = tile.zoom
        x = tile.x
        y = tile.y
        firstUnlockedAt = unlockedAt
        lastUnlockedAt = unlockedAt
        unlockCount = 1
    }

    var tile: ExplorationTile {
        ExplorationTile(x: x, y: y, zoom: zoom)
    }

    func markUnlocked(at date: Date) {
        if date < firstUnlockedAt {
            firstUnlockedAt = date
        }

        if date > lastUnlockedAt {
            lastUnlockedAt = date
        }

        unlockCount += 1
    }
}
