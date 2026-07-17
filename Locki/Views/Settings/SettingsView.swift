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
                                : "Enable Background Exploration"
                        ) {
                            if viewModel.showsLocationOnboarding {
                                viewModel.requestLocationAccess()
                            } else {
                                viewModel.requestBackgroundLocationAccess()
                            }
                        }
                    }

                    Text("Foreground exploration is automatic. Always access enables movement-driven background updates and eligible system relaunches. Force quitting prevents further capture until Locki is opened again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle(
                        "Continuous Background Exploration",
                        isOn: Binding(
                            get: { viewModel.continuousBackgroundTrackingEnabled },
                            set: { viewModel.setContinuousBackgroundTrackingEnabled($0) }
                        )
                    )
                    Text("Off by default. Efficient mode checks for meaningful movement without keeping the blue location indicator active. Continuous mode provides street-level background detail but uses more battery and shows the system indicator.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Exploration") {
                    Label(viewModel.explorationStatusTitle, systemImage: viewModel.explorationStatusSystemImage)
                    LabeledContent("Cleared street cells", value: viewModel.exploredTileCount.formatted())
                    LabeledContent("Path matching", value: "Automatic")
                    LabeledContent("Pending path anchors", value: viewModel.pendingPathAnchorCount.formatted())
                    LabeledContent("Matched paths", value: viewModel.matchedPathCount.formatted())
                    LabeledContent("Coverage resolution", value: "Street level")
                    LabeledContent("Permanent storage", value: "Compact local masks")
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
                Text("Locki turns accepted precise locations into small explored-area mask cells, then discards the original location sample. It does not save a raw coordinate trail or place names.")
                Text("Coverage masks and aggregate totals are stored locally with SwiftData. Locki has no account, analytics, advertising, or server.")
            }

            Section("Automatic Path Matching") {
                Text("Sparse background fixes are reduced to ordered street-level cells. Locki keeps these quantized anchors for no more than six hours while it looks for one high-confidence path.")
                Text("Locki sends only two quantized endpoints to Apple Maps for walking, cycling, driving, or transit directions. Intermediate anchors stay on this device to reject ambiguous routes.")
                Text("After a match, Locki stores only the cleared coverage mask and deletes the consumed anchors. Returned route lines are never retained.")
            }

            Section("Background Exploration") {
                Text("Efficient background exploration is movement-driven and does not keep the blue location indicator active. iOS decides when significant movement updates are delivered.")
                Text("Continuous Background Exploration is optional. It improves street-level background coverage, uses more battery, and displays the system location indicator.")
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
