//
//  MapView.swift
//  Locki
//
//  Created by Max Oliinyk on 06.05.2026.
//

import SwiftUI

struct MapView: View {
    @Bindable var viewModel: MapViewModel

    var body: some View {
        ZStack {
            LockiMap(viewModel: viewModel)
                .ignoresSafeArea()

            VStack {
                if viewModel.showsLocationOnboarding {
                    MapLocationOnboarding(viewModel: viewModel)
                }

                Spacer()

                HStack {
                    Spacer()

                    Button("Recenter", systemImage: "location.fill") {
                        viewModel.recenterMap()
                    }
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .foregroundStyle(viewModel.canRecenterMap ? .primary : .secondary)
                    .frame(width: 44, height: 44)
                    .background(.regularMaterial, in: .circle)
                    .contentShape(.circle)
                    .disabled(!viewModel.canRecenterMap)
                }
            }
            .padding()
        }
    }
}

private struct MapLocationOnboarding: View {
    @Bindable var viewModel: MapViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Unlock your map", systemImage: "map.fill")
                .bold()
                .foregroundStyle(.primary)

            Text("Allow location access to reveal explored map tiles as you move.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(viewModel.locationPermissionButtonTitle, systemImage: "location") {
                viewModel.requestLocationAccess()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.regularMaterial, in: .rect(cornerRadius: 20))
    }
}

#Preview {
    @Previewable @State var viewModel = MapViewModel()

    MapView(viewModel: viewModel)
}
