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
    @State private var historyModel = HistoryModel()

    var body: some View {
        TabView {
            Tab("Map", systemImage: "map") {
                MapView(viewModel: mapViewModel, historyModel: historyModel)
            }

            Tab("Stats", systemImage: "chart.bar") {
                StatsView(historyModel: historyModel)
            }

            Tab("Journal", systemImage: "book.pages") {
                JournalView(historyModel: historyModel)
            }

            Tab("Settings", systemImage: "gearshape") {
                SettingsView(viewModel: mapViewModel, historyModel: historyModel)
            }
        }
        .task {
            mapViewModel.setApplicationIsActive(scenePhase != .background)
            historyModel.configure(
                modelContainer: modelContext.container,
                locationTracking: mapViewModel.locationTracking
            )
            mapViewModel.configurePersistence(modelContainer: modelContext.container)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                mapViewModel.flushCoverage()
            } else if newPhase == .active {
                historyModel.checkCurrentStay()
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
                HistoryMetadataRecord.self,
                TrajectoryChunkRecord.self,
                HistoryTripRecord.self,
                HistoryVisitRecord.self,
                HistoryPlaceRecord.self,
                HistoryRoutePatternRecord.self,
                HistoryDailySummaryRecord.self,
                HistoryGapRecord.self,
                PlaceSuggestionPreferenceRecord.self,
            ],
            inMemory: true
        )
}
