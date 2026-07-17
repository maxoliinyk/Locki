//
//  MapView.swift
//  Locki
//
//  Created by Max Oliinyk on 06.05.2026.
//

import SwiftData
import SwiftUI

struct MapView: View {
    @Query(sort: \HistoryVisitRecord.arrivalDate, order: .reverse) private var visits: [HistoryVisitRecord]
    @Query private var places: [HistoryPlaceRecord]

    @Bindable var viewModel: MapViewModel
    let historyModel: HistoryModel

    private var currentVisit: HistoryVisitRecord? {
        visits.first { $0.departureDate == nil && !$0.isExcluded }
    }

    private var currentPlace: HistoryPlaceRecord? {
        guard let placeID = currentVisit?.placeID else { return nil }
        return places.first { $0.id == placeID && !$0.isExcluded }
    }

    private var provisionalPlace: HistoryPlaceRecord? {
        guard let placeID = historyModel.overview.provisionalStay?.placeID else { return nil }
        return places.first { $0.id == placeID && !$0.isExcluded }
    }

    var body: some View {
        ZStack {
            LockiMap(viewModel: viewModel)

            VStack(alignment: .leading) {
                if viewModel.showsLocationOnboarding {
                    MapLocationOnboarding(viewModel: viewModel)
                }

                Spacer()

                HStack(alignment: .bottom) {
                    if let currentVisit {
                        if let currentPlace {
                            NavigationLink {
                                PlaceDetailView(place: currentPlace, historyModel: historyModel)
                            } label: {
                                MapCurrentStayCard(place: currentPlace, visit: currentVisit)
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: 300)
                        } else {
                            MapCurrentStayCard(place: nil, visit: currentVisit)
                                .frame(maxWidth: 300)
                        }
                    } else if let provisional = historyModel.overview.provisionalStay {
                        MapProvisionalStayCard(stay: provisional, place: provisionalPlace)
                            .frame(maxWidth: 300)
                    } else if !historyModel.isEnabled, !viewModel.showsLocationOnboarding {
                        MapHistoryOffCard {
                            historyModel.setEnabled(true)
                        }
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

struct MapProvisionalStayCard: View {
    let stay: ProvisionalStaySnapshot
    let place: HistoryPlaceRecord?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if stay.isCredible(at: context.date) {
                HStack {
                    Image(systemName: "location.magnifyingglass")
                        .imageScale(.large)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(place.map { "Checking \($0.name)" } ?? "Checking this place")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(max(context.date.timeIntervalSince(stay.startedAt), 0).formattedDuration)
                            .font(.title2.weight(.semibold))
                            .monospacedDigit()
                    }
                    Spacer()
                }
                .padding()
                .background(.regularMaterial, in: .rect(cornerRadius: 20))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(place.map { "Checking stay at \($0.name)" } ?? "Checking this place")
                .accessibilityValue(max(context.date.timeIntervalSince(stay.startedAt), 0).formattedDuration)
            }
        }
    }
}

struct MapHistoryOffCard: View {
    let enable: () -> Void

    var body: some View {
        VStack(alignment: .leading) {
            Label("Stay detection is off", systemImage: "clock.badge.exclamationmark")
                .font(.headline)
            Text("Enable private location history to detect stays, places, and routes on this device.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Enable Stay Detection", systemImage: "location.fill", action: enable)
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.regularMaterial, in: .rect(cornerRadius: 20))
    }
}

struct MapCurrentStayCard: View {
    let place: HistoryPlaceRecord?
    let visit: HistoryVisitRecord

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack {
                Image(systemName: "location.fill")
                    .imageScale(.large)
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 4) {
                    Text(place.map { "You're staying at \($0.name) for" } ?? "You're staying here for")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(max(context.date.timeIntervalSince(visit.arrivalDate), 0).formattedDuration)
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                }

                Spacer()
            }
            .padding()
            .background(.regularMaterial, in: .rect(cornerRadius: 20))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(place.map { "Currently staying at \($0.name)" } ?? "Currently staying here")
            .accessibilityValue(max(context.date.timeIntervalSince(visit.arrivalDate), 0).formattedDuration)
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
    @Previewable @State var historyModel = HistoryModel()

    MapView(viewModel: viewModel, historyModel: historyModel)
        .modelContainer(
            for: [
                ExploredTileRecord.self,
                CoverageChunkRecord.self,
                ExplorationSummaryRecord.self,
                PendingPathAnchorRecord.self,
                HistoryVisitRecord.self,
                HistoryPlaceRecord.self,
            ],
            inMemory: true
        )
}
