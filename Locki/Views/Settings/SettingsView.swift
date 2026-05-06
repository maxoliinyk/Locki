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
                    Label("On-device by default", systemImage: "lock")
                    Label("No accounts or analytics", systemImage: "network.slash")
                }

                Section("Tracking") {
                    Label(viewModel.locationPermissionTitle, systemImage: viewModel.locationPermissionSystemImage)
                    Text(viewModel.locationPermissionDescription)
                        .foregroundStyle(.secondary)

                    Label("Fog of war is planned for later", systemImage: "map")
                }
            }
            .navigationTitle("Settings")
        }
    }
}

#Preview {
    @Previewable @State var viewModel = MapViewModel()

    SettingsView(viewModel: viewModel)
}
