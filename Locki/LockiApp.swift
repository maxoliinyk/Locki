//
//  LockiApp.swift
//  Locki
//
//  Created by Max Oliinyk on 06.05.2026.
//

import SwiftData
import SwiftUI

@main
struct LockiApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(for: [ExploredTileRecord.self, CoverageChunkRecord.self, ExplorationSummaryRecord.self])
    }
}
