//
//  RootView.swift
//  Locki
//
//  Created by Max Oliinyk on 06.05.2026.
//

import SwiftData
import SwiftUI

struct RootView: View {
    let runtime: AppRuntime

    private var mapViewModel: MapViewModel { runtime.mapViewModel }
    private var historyModel: HistoryModel { runtime.historyModel }

    var body: some View {
        TabView {
            Tab("Map", systemImage: "map") {
                NavigationStack {
                    MapView(viewModel: mapViewModel, historyModel: historyModel)
                }
            }

            Tab("Places", systemImage: "mappin.and.ellipse") {
                NavigationStack {
                    PlacesView(historyModel: historyModel)
                }
            }

            Tab("Journal", systemImage: "book.pages") {
                JournalView(historyModel: historyModel)
            }

            Tab("Stats", systemImage: "chart.bar") {
                StatsView(historyModel: historyModel)
            }

            Tab("Settings", systemImage: "gearshape") {
                SettingsView(
                    viewModel: mapViewModel,
                    historyModel: historyModel,
                    motionService: runtime.motionService,
                    trackingHealth: runtime.trackingHealth
                )
            }
        }
    }
}

#Preview {
    let container = try! ModelContainer(
        for: Schema([
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
            ]),
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    RootView(runtime: AppRuntime(modelContainer: container))
        .modelContainer(container)
}
