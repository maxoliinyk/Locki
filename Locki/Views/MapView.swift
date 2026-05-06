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
                StatusCard(
                    title: viewModel.statusTitle,
                    message: viewModel.statusDescription,
                    systemImage: viewModel.statusSystemImage,
                    tint: viewModel.statusTint
                )

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

//                MapSummaryPanel(viewModel: viewModel)
            }
            .padding()
        }
        .task {
            viewModel.requestLocationAccess()
        }
    }
}

#Preview {
    @Previewable @State var viewModel = MapViewModel()

    MapView(viewModel: viewModel)
}
