//
//  GapDetailView.swift
//  Locki
//
//  Created by Max Oliinyk on 18.07.2026.
//

import MapKit
import SwiftUI
import UIKit

struct GapDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let gapID: UUID
    let historyModel: HistoryModel

    @State private var snapshot: HistoryGapSnapshot?
    @State private var selectedMode = HistoryGapTravelMode.walking
    @State private var selectedSuggestionID: UUID?
    @State private var showsSaveError = false

    private var suggestions: [GapRouteSuggestion] {
        historyModel.gapRouteSuggestions[gapID] ?? []
    }

    private var selectedSuggestion: GapRouteSuggestion? {
        suggestions.first { $0.id == selectedSuggestionID }
    }

    var body: some View {
        List {
            if let snapshot {
                Section {
                    GapDetailMap(snapshot: snapshot, suggestions: suggestions, selectedID: selectedSuggestionID)
                        .frame(minHeight: 240)
                        .clipShape(.rect(cornerRadius: 16))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(snapshot.mapAccessibilityLabel)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

                Section("What Happened") {
                    Label(snapshot.diagnosis.displayName, systemImage: "exclamationmark.triangle")
                    LabeledContent("Started") { Text(snapshot.startedAt, format: .dateTime) }
                    if let endedAt = snapshot.endedAt {
                        LabeledContent("Ended") { Text(endedAt, format: .dateTime) }
                    } else {
                        LabeledContent("Status", value: "Ongoing")
                    }
                    if let duration = snapshot.duration {
                        LabeledContent("Missing interval", value: duration.formattedDuration)
                    }
                    Text(snapshot.explanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                recoverySection(snapshot)

                if snapshot.assessment.canRequestRoutes {
                    routeRepairSection(snapshot)
                } else if let reason = snapshot.assessment.routeIneligibility {
                    Section("Route Repair") {
                        ContentUnavailableView(
                            "No Reliable Route Suggestion",
                            systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                            description: Text(reason.displayName)
                        )
                    }
                }

                resolutionSection(snapshot)
            } else {
                Section {
                    ProgressView("Loading gap details…")
                }
            }
        }
        .navigationTitle("Tracking Gap")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onDisappear { historyModel.cancelGapRouteRequest(id: gapID) }
        .alert("Couldn’t Save Change", isPresented: $showsSaveError) {
            Button("OK") {}
        } message: {
            Text("Locki couldn’t save this gap update. Your existing history was not changed.")
        }
    }

    @ViewBuilder
    private func recoverySection(_ snapshot: HistoryGapSnapshot) -> some View {
        switch snapshot.reason {
        case .authorization, .reducedAccuracy:
            Section("Prevent Future Gaps") {
                Button("Open Location Settings", systemImage: "gear") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
        case .disabled:
            Section("Prevent Future Gaps") {
                Button("Enable Location History", systemImage: "location.fill") {
                    historyModel.setEnabled(true)
                }
            }
        case .persistence:
            Section("Prevent Future Gaps") {
                Text("Keep enough free device storage and reopen Locki if saving continues to fail.")
                    .foregroundStyle(.secondary)
            }
        case .discontinuity, .unavailable:
            EmptyView()
        }
    }

    private func routeRepairSection(_ snapshot: HistoryGapSnapshot) -> some View {
        Section("Possible Route") {
            Picker("Travel mode", selection: $selectedMode) {
                ForEach(HistoryGapTravelMode.allCases) { mode in
                    Label(mode.displayName, systemImage: mode.systemImage).tag(mode)
                }
            }

            Button("Find Possible Routes", systemImage: "arrow.triangle.turn.up.right.diamond") {
                Task {
                    let found = await historyModel.findGapRoutes(id: gapID, mode: selectedMode)
                    guard found else { return }
                    selectedSuggestionID = suggestions.first(where: \.isRecommended)?.id ?? suggestions.first?.id
                }
            }
            .disabled(historyModel.gapRouteLoadingIDs.contains(gapID))

            Text("This sends only the two quantized gap endpoints to Apple Maps after you tap the button.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if historyModel.gapRouteLoadingIDs.contains(gapID) {
                ProgressView("Finding routes…")
            } else if historyModel.gapRouteFailureIDs.contains(gapID) {
                Label("No suitable route was returned. Try another travel mode.", systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                Button {
                    selectedSuggestionID = suggestion.id
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(suggestion.isRecommended ? "Recommended" : suggestion.mode.displayName)
                                .font(.headline)
                            Text("\(suggestion.distanceMeters.formattedDistance) · \(suggestion.expectedTravelTime.formattedDuration)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selectedSuggestionID == suggestion.id {
                            Image(systemName: "checkmark.circle.fill")
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Route option \(index + 1), \(suggestion.mode.displayName), \(suggestion.distanceMeters.formattedDistance), \(suggestion.expectedTravelTime.formattedDuration)")
                .accessibilityValue(selectedSuggestionID == suggestion.id ? "Selected" : suggestion.isRecommended ? "Recommended" : "Not selected")
            }

            if let selectedSuggestion {
                Button("Confirm Estimated Route", systemImage: "checkmark") {
                    Task {
                        if await historyModel.confirmGapRoute(id: gapID, suggestion: selectedSuggestion) {
                            await load()
                        } else {
                            showsSaveError = true
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func resolutionSection(_ snapshot: HistoryGapSnapshot) -> some View {
        Section("Resolution") {
            if snapshot.resolution == .confirmedRoute {
                Label("Saved as an estimated route", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.orange)
                Text("Measured distance, statistics, completeness, and exploration coverage remain unchanged.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Undo Route Repair", systemImage: "arrow.uturn.backward") {
                    Task { await restore() }
                }
            } else if snapshot.resolution == .noMovement {
                Label("Marked as no movement", systemImage: "figure.stand")
                Text("This interval does not appear as a gap or reduce history completeness.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Undo Resolution", systemImage: "arrow.uturn.backward") {
                    Task { await restore() }
                }
            } else if snapshot.resolution == .dismissed {
                Label("Dismissed from the Journal", systemImage: "eye.slash")
                Button("Restore Gap", systemImage: "arrow.uturn.backward") {
                    Task { await restore() }
                }
            } else {
                if snapshot.reason == .discontinuity {
                    Button("I Stayed Here", systemImage: "figure.stand") {
                        Task {
                            if await historyModel.markGapAsNoMovement(id: gapID) { await load() }
                            else { showsSaveError = true }
                        }
                    }
                }
                Button("Dismiss from Journal", systemImage: "eye.slash") {
                    Task {
                        if await historyModel.dismissGap(id: gapID) { dismiss() }
                        else { showsSaveError = true }
                    }
                }
                Text("Dismissing hides this notice but keeps the missing interval in completeness calculations.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func load() async {
        guard let value = await historyModel.gapSnapshot(id: gapID) else { return }
        snapshot = value
        selectedMode = value.travelMode ?? value.assessment.suggestedMode
        selectedSuggestionID = nil
    }

    private func restore() async {
        if await historyModel.restoreGap(id: gapID) { await load() }
        else { showsSaveError = true }
    }
}

private struct GapDetailMap: View {
    let snapshot: HistoryGapSnapshot
    let suggestions: [GapRouteSuggestion]
    let selectedID: UUID?

    var body: some View {
        Map(initialPosition: cameraPosition) {
            if snapshot.estimatedRoute.count >= 2 {
                MapPolyline(coordinates: snapshot.estimatedRoute.map(\.locationCoordinate))
                    .stroke(.orange, style: StrokeStyle(lineWidth: 6, dash: [8, 6]))
            }
            ForEach(suggestions) { suggestion in
                MapPolyline(coordinates: suggestion.coordinates.map(\.locationCoordinate))
                    .stroke(
                        selectedID == suggestion.id ? .blue : .gray.opacity(0.55),
                        lineWidth: selectedID == suggestion.id ? 6 : 3
                    )
            }
            if let start = snapshot.assessment.start {
                Marker("Last reliable point", systemImage: "circle.fill", coordinate: start.coordinate.locationCoordinate)
                    .tint(.green)
            }
            if let end = snapshot.assessment.end {
                Marker("Next reliable point", systemImage: "circle.fill", coordinate: end.coordinate.locationCoordinate)
                    .tint(.red)
            }
        }
        .mapStyle(.standard)
        .mapControls { MapCompass(); MapScaleView() }
    }

    private var cameraPosition: MapCameraPosition {
        let coordinates = snapshot.estimatedRoute
            + suggestions.flatMap(\.coordinates)
            + [snapshot.assessment.start?.coordinate, snapshot.assessment.end?.coordinate].compactMap { $0 }
        guard !coordinates.isEmpty else { return .automatic }
        var rect = MKMapRect.null
        for coordinate in coordinates {
            let point = MKMapPoint(coordinate.locationCoordinate)
            rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 1, height: 1))
        }
        return .rect(rect.insetBy(dx: -max(rect.width * 0.15, 1_000), dy: -max(rect.height * 0.15, 1_000)))
    }
}

private extension HistoryGapSnapshot {
    var explanation: String {
        switch diagnosis {
        case .prolongedUpdateInterval:
            "Locki received reliable locations on both sides of this interval, but they arrived too far apart to connect as measured movement."
        case .implausibleLocationJump:
            "The next reliable location implied movement too fast or too far to connect safely. Locki split the history instead of drawing a false line."
        case .permissionUnavailable:
            "iOS stopped granting the location access Locki needs for private history."
        case .preciseLocationUnavailable:
            "Approximate Location was not precise enough to save a trustworthy route."
        case .historyDisabled:
            "Location History was off during this interval."
        case .saveFailed:
            "Locki could not persist history during this interval."
        case .locationTemporarilyUnavailable:
            "iOS could not provide a reliable location for at least two minutes."
        case .unknownDiscontinuity:
            "This gap was saved before Locki recorded a more specific cause."
        }
    }

    var mapAccessibilityLabel: String {
        if assessment.start != nil, assessment.end != nil {
            "Map showing the last and next reliable locations around the tracking gap"
        } else {
            "No reliable endpoint map is available for this tracking gap"
        }
    }
}

private extension HistoryGapRouteIneligibility {
    var displayName: String {
        switch self {
        case .ongoing: "The gap is still ongoing."
        case .notDiscontinuity: "This gap was caused by settings or availability, not two disconnected movement points."
        case .missingEndpoints: "The saved history no longer contains reliable points on both sides."
        case .likelyNoMovement: "The surrounding points are close enough that no road route would be meaningful."
        case .tooFar: "The endpoints are more than 100 km apart."
        case .tooLong: "The gap is longer than two hours and has too many plausible paths."
        case .implausibleSpeed: "The endpoints imply an impossible travel speed."
        }
    }
}

nonisolated extension HistoryGapTravelMode {
    var displayName: String {
        switch self {
        case .walking: "Walking"
        case .cycling: "Cycling"
        case .automobile: "Driving"
        case .transit: "Transit"
        }
    }

    var systemImage: String {
        switch self {
        case .walking: "figure.walk"
        case .cycling: "bicycle"
        case .automobile: "car"
        case .transit: "tram"
        }
    }
}
