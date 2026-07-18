//
//  PlacesView.swift
//  Locki
//
//  Created by Max Oliinyk on 17.07.2026.
//

import SwiftData
import SwiftUI

struct PlacesView: View {
    @Query private var places: [HistoryPlaceRecord]
    @Query(sort: \HistoryVisitRecord.arrivalDate, order: .reverse) private var visits: [HistoryVisitRecord]

    let historyModel: HistoryModel
    @State private var searchText = ""
    @State private var sort = PlaceSort.totalTime

    private var includedPlaces: [HistoryPlaceRecord] { places.filter { !$0.isExcluded } }
    private var visitSnapshots: [PlaceVisitPresentationSnapshot] {
        visits.map {
            PlaceVisitPresentationSnapshot(
                placeID: $0.placeID,
                arrivalDate: $0.arrivalDate,
                departureDate: $0.departureDate,
                timeZoneIdentifier: $0.timeZoneIdentifier,
                isExcluded: $0.isExcluded
            )
        }
    }
    private var hasSearchQuery: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private func favorites(using metrics: [UUID: PlaceDisplayMetrics]) -> [HistoryPlaceRecord] {
        includedPlaces.filter(\.isFavorite).sorted {
            let leftDuration = metrics[$0.id, default: .zero].totalDuration
            let rightDuration = metrics[$1.id, default: .zero].totalDuration
            return leftDuration == rightDuration
                ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                : leftDuration > rightDuration
        }
    }
    private func frequent(using metrics: [UUID: PlaceDisplayMetrics]) -> [HistoryPlaceRecord] {
        includedPlaces.filter { isFrequent($0, using: metrics) }.sorted {
            let leftDuration = metrics[$0.id, default: .zero].totalDuration
            let rightDuration = metrics[$1.id, default: .zero].totalDuration
            return leftDuration == rightDuration
                ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                : leftDuration > rightDuration
        }
    }
    private func allPlaces(using metrics: [UUID: PlaceDisplayMetrics]) -> [HistoryPlaceRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let searched = includedPlaces.filter {
            query.isEmpty
                || $0.name.localizedStandardContains(query)
                || ($0.category?.localizedStandardContains(query) ?? false)
        }
        return searched.sorted { left, right in
            let leftMetrics = metrics[left.id, default: .zero]
            let rightMetrics = metrics[right.id, default: .zero]
            switch sort {
            case .totalTime:
                return leftMetrics.totalDuration == rightMetrics.totalDuration
                    ? left.name.localizedStandardCompare(right.name) == .orderedAscending
                    : leftMetrics.totalDuration > rightMetrics.totalDuration
            case .recent:
                let leftDate = left.lastVisitAt ?? .distantPast
                let rightDate = right.lastVisitAt ?? .distantPast
                return leftDate == rightDate
                    ? left.name.localizedStandardCompare(right.name) == .orderedAscending
                    : leftDate > rightDate
            case .visits:
                if leftMetrics.visitCount != rightMetrics.visitCount {
                    return leftMetrics.visitCount > rightMetrics.visitCount
                }
                return leftMetrics.totalDuration == rightMetrics.totalDuration
                    ? left.name.localizedStandardCompare(right.name) == .orderedAscending
                    : leftMetrics.totalDuration > rightMetrics.totalDuration
            case .name:
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
        }
    }
    private var currentVisit: HistoryVisitRecord? {
        visits.first { $0.departureDate == nil && !$0.isExcluded }
    }
    private var currentPlace: HistoryPlaceRecord? {
        guard let placeID = currentVisit?.placeID else { return nil }
        return places.first { $0.id == placeID }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let metrics = PlacePresentation.metrics(visits: visitSnapshots, now: context.date)
            placesList(metrics: metrics, now: context.date)
        }
    }

    private func placesList(metrics: [UUID: PlaceDisplayMetrics], now: Date) -> some View {
        List {
            if !hasSearchQuery, let currentVisit {
                Section("Now") {
                    CurrentPlaceCard(place: currentPlace, visit: currentVisit, now: now)
                }
            }

            let favoritePlaces = favorites(using: metrics)
            if !hasSearchQuery, !favoritePlaces.isEmpty {
                Section("Favorites") {
                    ForEach(favoritePlaces.prefix(5)) { place in
                        placeRow(place, metrics: metrics[place.id, default: .zero])
                    }
                }
            }

            let frequentPlaces = frequent(using: metrics)
            if !hasSearchQuery, !frequentPlaces.isEmpty {
                Section {
                    ForEach(frequentPlaces.prefix(5)) { place in
                        placeRow(place, metrics: metrics[place.id, default: .zero])
                    }
                } header: {
                    Text("Frequent Places")
                } footer: {
                    Text("Frequent means at least 3 visits across 2 days and 30 minutes total.")
                }
            }

            let displayedPlaces = allPlaces(using: metrics)
            Section(hasSearchQuery ? "Results" : "All Places") {
                if displayedPlaces.isEmpty {
                    if hasSearchQuery {
                        ContentUnavailableView.search(text: searchText)
                    } else {
                        ContentUnavailableView(
                            "No Places Yet",
                            systemImage: "mappin.slash",
                            description: Text("Places will appear after Locki detects a stay.")
                        )
                    }
                } else {
                    ForEach(displayedPlaces) { place in
                        placeRow(place, metrics: metrics[place.id, default: .zero])
                    }
                }
            }
        }
        .navigationTitle("Places")
        .searchable(text: $searchText, prompt: "Search places")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Sort places", systemImage: "arrow.up.arrow.down") {
                    Picker("Sort", selection: $sort) {
                        ForEach(PlaceSort.allCases) { Text($0.title).tag($0) }
                    }
                }
                .accessibilityLabel("Sort places")
            }
        }
    }

    private func isFrequent(
        _ place: HistoryPlaceRecord,
        using metrics: [UUID: PlaceDisplayMetrics]
    ) -> Bool {
        let placeMetrics = metrics[place.id, default: .zero]
        return placeMetrics.visitCount >= FrequentPlaceRanker.minimumVisitCount
            && placeMetrics.distinctDayCount >= FrequentPlaceRanker.minimumDistinctDayCount
            && placeMetrics.totalDuration >= FrequentPlaceRanker.minimumDuration
    }

    private func placeRow(_ place: HistoryPlaceRecord, metrics: PlaceDisplayMetrics) -> some View {
        NavigationLink {
            PlaceDetailView(place: place, historyModel: historyModel)
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    HStack {
                        Text(place.name).font(.headline)
                        if place.isFavorite {
                            Image(systemName: "star.fill")
                                .foregroundStyle(.yellow)
                                .accessibilityHidden(true)
                        }
                    }
                    Text(metrics.countSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(metrics.totalDuration.formattedDuration)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(place.name)
            .accessibilityValue(
                "\(metrics.totalDuration.formattedDuration), \(metrics.countSummary)\(place.isFavorite ? ", favorite" : "")"
            )
        }
    }
}

struct CurrentPlaceCard: View {
    let place: HistoryPlaceRecord?
    let visit: HistoryVisitRecord
    let now: Date

    var body: some View {
        Label {
            VStack(alignment: .leading) {
                Text("At \(place?.name ?? "Unrecognized place")")
                    .font(.headline)
                Text(max(now.timeIntervalSince(visit.arrivalDate), 0).formattedDuration)
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
            }
        } icon: {
            Image(systemName: "location.fill")
                .foregroundStyle(.blue)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Currently at \(place?.name ?? "an unrecognized place")")
        .accessibilityValue(max(now.timeIntervalSince(visit.arrivalDate), 0).formattedDuration)
    }
}

private enum PlaceSort: String, CaseIterable, Identifiable {
    case totalTime
    case recent
    case visits
    case name

    var id: String { rawValue }
    var title: String {
        switch self {
        case .totalTime: "Total Time"
        case .recent: "Most Recent"
        case .visits: "Visit Count"
        case .name: "Name"
        }
    }
}
