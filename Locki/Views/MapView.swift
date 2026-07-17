//
//  MapView.swift
//  Locki
//
//  Created by Max Oliinyk on 06.05.2026.
//

import SwiftData
import SwiftUI

struct MapView: View {
    @Bindable var viewModel: MapViewModel

    var body: some View {
        ZStack {
            LockiMap(viewModel: viewModel)

            VStack(alignment: .leading) {
                if viewModel.showsLocationOnboarding {
                    MapLocationOnboarding(viewModel: viewModel)
                }

                Spacer()

                HStack(alignment: .bottom) {
                    if !viewModel.showsLocationOnboarding {
                        StatusCard(
                            title: viewModel.explorationStatusTitle,
                            message: viewModel.explorationStatusMessage,
                            systemImage: viewModel.explorationStatusSystemImage,
                            tint: viewModel.locationTracking.state.tint
                        )
                        .frame(maxWidth: 300)
                    }

                    Spacer()

                    MapControlStack(viewModel: viewModel)
                }
            }
            .padding()
        }
    }
}

private struct MapControlStack: View {
    @Bindable var viewModel: MapViewModel

    var body: some View {
        VStack(spacing: 10) {
            if viewModel.locationTracking.state == .requiresPreciseLocation {
                Button("Request Precise Location", systemImage: "scope") {
                    viewModel.requestPreciseLocation()
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel("Request precise location")
                .mapChromeButton()
            }

            Menu {
                Picker("Map Style", selection: $viewModel.mapStyle) {
                    ForEach(LockiMapStyle.allCases) { style in
                        Label(style.title, systemImage: style.systemImage)
                            .tag(style)
                    }
                }
            } label: {
                Label("Map Style", systemImage: viewModel.mapStyle.systemImage)
                    .labelStyle(.iconOnly)
            }
            .accessibilityLabel("Map style")
            .mapChromeButton()

            Button("Recenter", systemImage: "location.fill") {
                viewModel.recenterMap()
            }
            .labelStyle(.iconOnly)
            .accessibilityLabel("Recenter map")
            .disabled(!viewModel.canRecenterMap)
            .mapChromeButton(isEnabled: viewModel.canRecenterMap)
        }
    }
}

private struct MapChromeButton: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        content
            .font(.title3)
            .foregroundStyle(isEnabled ? .primary : .secondary)
            .frame(width: 44, height: 44)
            .background(.regularMaterial, in: .circle)
            .contentShape(.circle)
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }
}

private extension View {
    func mapChromeButton(isEnabled: Bool = true) -> some View {
        modifier(MapChromeButton(isEnabled: isEnabled))
    }
}

private extension LocationTrackingState {
    var tint: Color {
        switch self {
        case .waitingForPermission, .stationary:
            .secondary
        case .active:
            .mint
        case .requiresPreciseLocation, .unavailable, .failed:
            .orange
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

            Text(viewModel.locationPermissionDescription)
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
        .modelContainer(
            for: [ExploredTileRecord.self, CoverageChunkRecord.self, ExplorationSummaryRecord.self],
            inMemory: true
        )
}
