//
//  MapSummaryPanel.swift
//  Locki
//
//  Created by Max Oliinyk on 06.05.2026.
//

import SwiftUI

struct MapSummaryPanel: View {
    @Bindable var viewModel: MapViewModel
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.snappy) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "square.grid.2x2.fill")
                        .foregroundStyle(.blue)
                        .imageScale(.medium)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Explored \(viewModel.exploredPlacesCount.formatted()) areas")
                            .bold()
                            .foregroundStyle(.primary)

                        Text(viewModel.statusTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                        .font(.caption)
                        .bold()
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    SummaryMetric(
                        title: "Explored areas",
                        value: viewModel.exploredPlacesCount.formatted()
                    )

                    Text(viewModel.statusDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(14)
        .background(.regularMaterial, in: .rect(cornerRadius: 18))
    }
}

#Preview {
    @Previewable @State var viewModel = MapViewModel()

    MapSummaryPanel(viewModel: viewModel)
        .padding()
}
