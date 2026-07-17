//
//  PlaceDetailView.swift
//  Locki
//
//  Created by Max Oliinyk on 17.07.2026.
//

import Charts
import CoreLocation
import MapKit
import SwiftData
import SwiftUI

struct PlaceDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var allPlaces: [HistoryPlaceRecord]
    @Query(sort: \HistoryVisitRecord.arrivalDate, order: .reverse) private var allVisits: [HistoryVisitRecord]
    @Query private var suggestionPreferences: [PlaceSuggestionPreferenceRecord]

    let place: HistoryPlaceRecord
    let historyModel: HistoryModel
    @State private var name = ""
    @State private var category = ""
    @State private var lookupState: LookupState = .idle
    @State private var mergeTarget: HistoryPlaceRecord?
    @State private var period = PlaceDetailPeriod.month

    private var visits: [HistoryVisitRecord] { allVisits.filter { $0.placeID == place.id } }
    private var analytics: PlaceAnalyticsSnapshot {
        PlaceAnalyticsEngine().snapshot(
            visits: visits.map(\.snapshot),
            periodStart: period.start,
            now: .now
        )
    }
    private var suggestion: PlaceLabelSuggestion? {
        PlaceLabelSuggestionEngine().suggestions(
            for: allPlaces.map { candidate in
                PlaceSuggestionInput(
                    id: candidate.id,
                    visits: allVisits.filter { $0.placeID == candidate.id }.map(\.snapshot),
                    dismissedSuggestion: suggestionPreferences
                        .first { $0.placeID == candidate.id }
                        .flatMap { PlaceLabelSuggestion(rawValue: $0.dismissedSuggestionRawValue) }
                )
            },
            now: .now
        )[place.id]
    }

    var body: some View {
        List {
            Section {
                Map(initialPosition: .region(region)) {
                    Marker(place.name, coordinate: coordinate)
                    MapCircle(center: coordinate, radius: place.radiusMeters)
                        .foregroundStyle(.blue.opacity(0.12))
                        .stroke(.blue, lineWidth: 1)
                }
                .frame(minHeight: 220)
                .clipShape(.rect(cornerRadius: 16))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Map showing \(place.name)")
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            Section("Place") {
                TextField("Name", text: $name)
                TextField("Category", text: $category)
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(["Home", "Work", "School", "Park", "Gym"], id: \.self) { label in
                            Button(label) {
                                name = label
                                category = label
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                Toggle(
                    "Favorite",
                    isOn: Binding(
                        get: { place.isFavorite },
                        set: { historyModel.setFavorite(placeID: place.id, isFavorite: $0) }
                    )
                )
                Toggle(
                    "Exclude from rankings",
                    isOn: Binding(
                        get: { place.isExcluded },
                        set: { historyModel.setPlaceExcluded(id: place.id, isExcluded: $0) }
                    )
                )
                Button("Save Changes", systemImage: "checkmark") {
                    Task {
                        _ = await historyModel.updatePlace(
                            id: place.id,
                            name: name.isEmpty ? place.name : name,
                            category: category.isEmpty ? nil : category
                        )
                    }
                }
            }

            if let suggestion {
                Section("Suggested Label") {
                    Label("This may be your \(suggestion.rawValue.lowercased()).", systemImage: "sparkles")
                    Button("Name It \(suggestion.rawValue)") {
                        name = suggestion.rawValue
                        category = suggestion.rawValue
                        Task {
                            _ = await historyModel.updatePlace(
                                id: place.id,
                                name: suggestion.rawValue,
                                category: suggestion.rawValue,
                                source: "suggestion"
                            )
                        }
                    }
                    Button("Dismiss Suggestion", role: .cancel) {
                        historyModel.dismissLabelSuggestion(placeID: place.id, suggestion: suggestion)
                    }
                }
            }

            Section("Apple Maps") {
                Button("Identify This Place", systemImage: "map") { identifyPlace() }
                    .disabled(lookupState == .loading)
                switch lookupState {
                case .idle: Text("Only this place's center is sent when you request identification.")
                case .loading: ProgressView("Looking up place")
                case .failed: Text("Apple Maps could not identify this place.").foregroundStyle(.secondary)
                case .found(let value): Text("Found \(value)").foregroundStyle(.secondary)
                }
            }

            Section("Statistics") {
                Picker("Period", selection: $period) {
                    ForEach(PlaceDetailPeriod.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if let current = analytics.currentVisit {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        LabeledContent(
                            "Current stay",
                            value: max(context.date.timeIntervalSince(current.arrivalDate), 0).formattedDuration
                        )
                    }
                }
                LabeledContent("Time in period", value: analytics.periodDuration.formattedDuration)
                LabeledContent("All-time total", value: analytics.allTimeDuration.formattedDuration)
                LabeledContent("Visits", value: analytics.visitCount.formatted())
                LabeledContent("Distinct days", value: analytics.distinctDayCount.formatted())
                LabeledContent("Average stay", value: analytics.averageDuration.formattedDuration)
                LabeledContent("Longest stay", value: analytics.longestDuration.formattedDuration)
                if let first = analytics.firstVisitAt { LabeledContent("First visit") { Text(first, format: .dateTime) } }
                if let last = analytics.lastVisitAt { LabeledContent("Latest visit") { Text(last, format: .dateTime) } }
                if visits.contains(where: { $0.quality < 0.5 }) {
                    Label("Some stay time is estimated from lower-accuracy evidence", systemImage: "approximately")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !analytics.trend.isEmpty {
                Section("Time by Day") {
                    Chart(analytics.trend) { bucket in
                        BarMark(
                            x: .value("Day", bucket.day, unit: .day),
                            y: .value("Hours", bucket.duration / 3_600)
                        )
                        .foregroundStyle(.blue)
                        .accessibilityLabel(bucket.day.formatted(date: .abbreviated, time: .omitted))
                        .accessibilityValue(bucket.duration.formattedDuration)
                    }
                    .chartYScale(domain: .automatic(includesZero: true))
                    .chartYAxisLabel("Hours")
                    .chartScrollableAxes(.horizontal)
                    .chartXVisibleDomain(length: min(TimeInterval(max(analytics.trend.count, 1)), 14) * 86_400)
                    .frame(minHeight: 220)
                }
            }

            if !analytics.heatmap.isEmpty {
                Section("Usual Times") {
                    Chart(analytics.heatmap) { bucket in
                        RectangleMark(
                            x: .value("Hour", bucket.hour),
                            y: .value("Weekday", weekdayName(bucket.weekday))
                        )
                        .foregroundStyle(.blue.opacity(heatmapOpacity(bucket.duration)))
                        .accessibilityLabel("\(weekdayName(bucket.weekday)) at \(bucket.hour):00")
                        .accessibilityValue(bucket.duration.formattedDuration)
                    }
                    .chartXAxis {
                        AxisMarks(values: [0, 6, 12, 18, 23])
                    }
                    .frame(minHeight: 240)
                    Text("Darker cells mean more time. Every cell is also described by VoiceOver.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !visits.isEmpty {
                Section("Recent Visits") {
                    ForEach(visits.prefix(20)) { visit in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(visit.arrivalDate, format: .dateTime.weekday().month().day().hour().minute())
                                Text(visit.duration.formattedDuration)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if visit.quality < 0.5 {
                                    Text("Estimated")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                            Menu("Visit corrections", systemImage: "ellipsis.circle") {
                                Button("Move to New Place", systemImage: "arrow.branch") {
                                    Task { _ = await historyModel.splitVisit(id: visit.id) }
                                }
                                Button("Delete Visit", systemImage: "trash", role: .destructive) {
                                    historyModel.deleteVisit(id: visit.id)
                                }
                            }
                            .labelStyle(.iconOnly)
                        }
                    }
                }
            }

            if allPlaces.count > 1 {
                Section("Corrections") {
                    Menu("Merge Into Another Place", systemImage: "arrow.triangle.merge") {
                        ForEach(allPlaces.filter { $0.id != place.id }) { target in
                            Button(target.name) { mergeTarget = target }
                        }
                    }
                }
            }
        }
        .navigationTitle(place.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            name = place.name
            category = place.category ?? ""
        }
        .confirmationDialog(
            "Merge \(place.name)?",
            isPresented: Binding(get: { mergeTarget != nil }, set: { if !$0 { mergeTarget = nil } }),
            presenting: mergeTarget
        ) { target in
            Button("Merge into \(target.name)", role: .destructive) {
                Task {
                    if await historyModel.mergePlaces(sourceID: place.id, destinationID: target.id) {
                        dismiss()
                    }
                }
            }
        } message: { target in
            Text("All visits from \(place.name) will be reassigned to \(target.name).")
        }
    }

    private var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
    }

    private var region: MKCoordinateRegion {
        MKCoordinateRegion(center: coordinate, latitudinalMeters: 800, longitudinalMeters: 800)
    }

    private func heatmapOpacity(_ duration: TimeInterval) -> Double {
        let maximum = analytics.heatmap.map(\.duration).max() ?? 1
        return max(0.15, min(duration / maximum, 1))
    }

    private func weekdayName(_ weekday: Int) -> String {
        let symbols = Calendar.current.shortWeekdaySymbols
        guard symbols.indices.contains(weekday - 1) else { return "Day \(weekday)" }
        return symbols[weekday - 1]
    }

    private func identifyPlace() {
        lookupState = .loading
        Task {
            do {
                let location = CLLocation(latitude: place.latitude, longitude: place.longitude)
                guard let request = MKReverseGeocodingRequest(location: location),
                      let item = try await request.mapItems.first,
                      let foundName = item.name,
                      !foundName.isEmpty else {
                    lookupState = .failed
                    return
                }
                name = foundName
                category = item.pointOfInterestCategory?.rawValue ?? category
                _ = await historyModel.updatePlace(
                    id: place.id,
                    name: foundName,
                    category: category.isEmpty ? nil : category,
                    source: "apple"
                )
                lookupState = .found(foundName)
            } catch {
                lookupState = .failed
            }
        }
    }
}

private enum PlaceDetailPeriod: String, CaseIterable, Identifiable {
    case week
    case month
    case year
    case all

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var start: Date {
        switch self {
        case .week: Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .distantPast
        case .month: Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .distantPast
        case .year: Calendar.current.date(byAdding: .year, value: -1, to: .now) ?? .distantPast
        case .all: .distantPast
        }
    }
}

private extension HistoryVisitRecord {
    var snapshot: PlaceVisitSnapshot {
        PlaceVisitSnapshot(
            id: id,
            arrivalDate: arrivalDate,
            departureDate: departureDate,
            timeZoneIdentifier: timeZoneIdentifier,
            isExcluded: isExcluded
        )
    }
}

private enum LookupState: Equatable {
    case idle
    case loading
    case failed
    case found(String)
}
