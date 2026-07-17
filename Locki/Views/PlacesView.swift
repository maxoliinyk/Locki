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
    private var favorites: [HistoryPlaceRecord] {
        includedPlaces.filter(\.isFavorite).sorted { $0.totalDuration > $1.totalDuration }
    }
    private var frequent: [HistoryPlaceRecord] {
        includedPlaces.filter(isFrequent).sorted { $0.totalDuration > $1.totalDuration }
    }
    private var allPlaces: [HistoryPlaceRecord] {
        let searched = includedPlaces.filter {
            searchText.isEmpty
                || $0.name.localizedStandardContains(searchText)
                || ($0.category?.localizedStandardContains(searchText) ?? false)
        }
        return searched.sorted { left, right in
            switch sort {
            case .totalTime: left.totalDuration == right.totalDuration
                ? left.name.localizedStandardCompare(right.name) == .orderedAscending
                : left.totalDuration > right.totalDuration
            case .recent: (left.lastVisitAt ?? .distantPast) > (right.lastVisitAt ?? .distantPast)
            case .visits: left.visitCount == right.visitCount
                ? left.totalDuration > right.totalDuration
                : left.visitCount > right.visitCount
            case .name: left.name.localizedStandardCompare(right.name) == .orderedAscending
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
        List {
            if let currentVisit {
                Section("Now") {
                    CurrentPlaceCard(place: currentPlace, visit: currentVisit)
                }
            }

            if !favorites.isEmpty {
                Section("Favorites") {
                    ForEach(favorites) { placeRow($0) }
                }
            }

            if !frequent.isEmpty {
                Section {
                    ForEach(frequent) { placeRow($0) }
                } header: {
                    Text("Frequent Places")
                } footer: {
                    Text("Frequent means at least 3 visits across 2 days and 30 minutes total.")
                }
            }

            Section("All Places") {
                if allPlaces.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    ForEach(allPlaces) { placeRow($0) }
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

    private func isFrequent(_ place: HistoryPlaceRecord) -> Bool {
        place.visitCount >= FrequentPlaceRanker.minimumVisitCount
            && place.distinctDayCount >= FrequentPlaceRanker.minimumDistinctDayCount
            && place.totalDuration >= FrequentPlaceRanker.minimumDuration
    }

    private func placeRow(_ place: HistoryPlaceRecord) -> some View {
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
                    Text("\(place.visitCount) visits · \(place.distinctDayCount) days")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(place.totalDuration.formattedDuration)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(place.name)
            .accessibilityValue("\(place.totalDuration.formattedDuration), \(place.visitCount) visits, \(place.distinctDayCount) days\(place.isFavorite ? ", favorite" : "")")
        }
    }
}

struct CurrentPlaceCard: View {
    let place: HistoryPlaceRecord?
    let visit: HistoryVisitRecord

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Label {
                VStack(alignment: .leading) {
                    Text("At \(place?.name ?? "Unrecognized place")")
                        .font(.headline)
                    Text(max(context.date.timeIntervalSince(visit.arrivalDate), 0).formattedDuration)
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                }
            } icon: {
                Image(systemName: "location.fill")
                    .foregroundStyle(.blue)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Currently at \(place?.name ?? "an unrecognized place")")
            .accessibilityValue(max(context.date.timeIntervalSince(visit.arrivalDate), 0).formattedDuration)
        }
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
