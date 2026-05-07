//
//  RootView.swift
//  Locki
//
//  Created by Max Oliinyk on 06.05.2026.
//

import SwiftUI

struct RootView: View {
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
    }
}

#Preview {
    RootView()
}
