//
//  SettingsView.swift
//  Locki
//
//  Created by Max Oliinyk on 06.05.2026.
//

import SwiftUI

struct SettingsView: View {
    @Bindable var viewModel: MapViewModel

    var body: some View {
        NavigationStack {
            List {
                Section("Privacy") {
                    Label("Coverage stays on this device", systemImage: "lock")
                    Label("No accounts, analytics, or raw trails", systemImage: "network.slash")
                    NavigationLink("How Locki Uses Location") {
                        LocationPrivacyView()
                    }
                }

                Section("Location") {
                    Label(viewModel.locationPermissionTitle, systemImage: viewModel.locationPermissionSystemImage)
                    Text(viewModel.locationPermissionDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !viewModel.locationTracking.hasAlwaysLocationAccess {
                        Button(
                            viewModel.showsLocationOnboarding
                                ? viewModel.locationPermissionButtonTitle
                                : "Enable Always Location"
                        ) {
                            viewModel.requestLocationAccess()
                        }
                    }

                    Text("Exploration runs whenever location access is available, including while Locki is in the background. Always access also supports eligible system relaunches. Force quitting prevents further capture until Locki is opened again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Exploration") {
                    Label(viewModel.explorationStatusTitle, systemImage: viewModel.explorationStatusSystemImage)
                    LabeledContent("Cleared street cells", value: viewModel.exploredTileCount.formatted())
                    LabeledContent("Coverage resolution", value: "Street level")
                    LabeledContent("Storage", value: "Compact local masks")
                }
            }
            .navigationTitle("Settings")
        }
    }
}

private struct LocationPrivacyView: View {
    var body: some View {
        List {
            Section("On Device") {
                Text("Locki turns accepted precise locations into small explored-area mask cells, then discards the location sample. It does not save a coordinate trail, speed history, or place names.")
                Text("Coverage masks and aggregate totals are stored locally with SwiftData. Locki has no account, analytics, advertising, or location upload.")
            }

            Section("Background Exploration") {
                Text("Locki continuously clears fog after you lock the screen or switch apps. iOS shows its background location indicator while location work continues.")
                Text("Always Location supports eligible system relaunches. Force quitting prevents further capture until Locki is opened again.")
            }

            Section("Control") {
                Text("You can change location permission at any time in Settings. Deleting Locki removes its local coverage database.")
            }
        }
        .navigationTitle("Location Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    @Previewable @State var viewModel = MapViewModel()
    SettingsView(viewModel: viewModel)
}
