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
//                .ignoresSafeArea()

            VStack {
                if viewModel.showsLocationOnboarding {
                    MapLocationOnboarding(viewModel: viewModel)
                }

                Spacer()

                HStack {
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
            .mapChromeButton()

            Button("Recenter", systemImage: "location.fill") {
                viewModel.recenterMap()
            }
            .labelStyle(.iconOnly)
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
