//
//  RootView.swift
//  Locki
//
//  Created by Max Oliinyk on 06.05.2026.
//

import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var mapViewModel = MapViewModel()

    var body: some View {
        TabView {
            Tab("Map", systemImage: "map") {
                MapView(viewModel: mapViewModel)
            }

            Tab("Stats", systemImage: "chart.bar") {
                StatsView()
            }

            Tab("Journal", systemImage: "book.pages") {
                JournalView()
            }

            Tab("Settings", systemImage: "gearshape") {
                SettingsView(viewModel: mapViewModel)
            }
        }
        .task {
            mapViewModel.setApplicationIsActive(scenePhase != .background)
            mapViewModel.configurePersistence(modelContainer: modelContext.container)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                mapViewModel.flushCoverage()
            }
            mapViewModel.setApplicationIsActive(newPhase != .background)
        }
    }
}

#Preview {
    RootView()
        .modelContainer(
            for: [
                ExploredTileRecord.self,
                CoverageChunkRecord.self,
                ExplorationSummaryRecord.self,
                PendingPathAnchorRecord.self,
            ],
            inMemory: true
        )
}
