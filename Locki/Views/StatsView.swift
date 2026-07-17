//
//  StatsView.swift
//  Locki
//
//  Created by Max Oliinyk on 07.05.2026.
//

import Charts
import MapKit
import SwiftData
import SwiftUI

struct StatsView: View {
    @Query private var explorationSummaries: [ExplorationSummaryRecord]
    @Query(sort: \HistoryDailySummaryRecord.dayStart) private var days: [HistoryDailySummaryRecord]
    @Query private var places: [HistoryPlaceRecord]
    @Query private var routes: [HistoryRoutePatternRecord]
    @Query private var trips: [HistoryTripRecord]
    @Query private var visits: [HistoryVisitRecord]

    let historyModel: HistoryModel
    @State private var period: StatsPeriod = .month

    private var explorationSummary: ExplorationSummaryRecord? {
        explorationSummaries.first { $0.key == "primary" }
    }

    private var periodStart: Date {
        let calendar = Calendar.current
        return switch period {
        case .week: calendar.date(byAdding: .day, value: -7, to: .now) ?? .distantPast
        case .month: calendar.date(byAdding: .month, value: -1, to: .now) ?? .distantPast
        case .year: calendar.date(byAdding: .year, value: -1, to: .now) ?? .distantPast
        case .all: .distantPast
        }
    }

    private var filteredDays: [HistoryDailySummaryRecord] { days.filter { $0.dayStart >= periodStart } }
    private var filteredTrips: [HistoryTripRecord] {
        trips.filter {
            $0.startedAt >= periodStart
                && !$0.isExcluded
                && ($0.distanceMeters >= HistoryConfiguration.standard.minimumTripDistanceMeters
                    || $0.elapsedDuration >= HistoryConfiguration.standard.minimumTripDuration)
        }
    }
    private var filteredVisits: [HistoryVisitRecord] {
        visits.filter { ($0.departureDate ?? .now) >= periodStart && !$0.isExcluded }
    }
    private var distance: Double { filteredDays.reduce(0) { $0 + $1.distanceMeters } }
    private var movingDuration: TimeInterval { filteredDays.reduce(0) { $0 + $1.movingDuration } }
    private var placeDuration: TimeInterval { filteredVisits.reduce(0) { result, visit in
        let start = max(visit.arrivalDate, periodStart)
        return result + max((visit.departureDate ?? .now).timeIntervalSince(start), 0)
    } }

    private var currentVisit: HistoryVisitRecord? {
        visits.first { $0.departureDate == nil && !$0.isExcluded }
    }

    private var currentPlace: HistoryPlaceRecord? {
        guard let placeID = currentVisit?.placeID else { return nil }
        return places.first { $0.id == placeID }
    }

    private var favoritePlaces: [HistoryPlaceRecord] {
        places
            .filter { place in
                let visits = filteredVisits.filter { $0.placeID == place.id }
                let days = Set(visits.map { Calendar.current.startOfDay(for: $0.arrivalDate) }).count
                let duration = visits.reduce(0) { result, visit in
                    let start = max(visit.arrivalDate, periodStart)
                    return result + max((visit.departureDate ?? .now).timeIntervalSince(start), 0)
                }
                return !place.isExcluded
                    && (place.isFavorite
                        || (visits.count >= FrequentPlaceRanker.minimumVisitCount
                            && days >= FrequentPlaceRanker.minimumDistinctDayCount
                            && duration >= FrequentPlaceRanker.minimumDuration))
            }
            .sorted {
                if $0.isFavorite != $1.isFavorite { return $0.isFavorite }
                if periodDuration(at: $0.id) != periodDuration(at: $1.id) {
                    return periodDuration(at: $0.id) > periodDuration(at: $1.id)
                }
                return ($0.lastVisitAt ?? .distantPast) > ($1.lastVisitAt ?? .distantPast)
            }
            .prefix(5)
            .map { $0 }
    }

    private var favoriteRoutes: [HistoryRoutePatternRecord] {
        routes
            .filter { route in
                !route.isExcluded && (route.isFavorite || filteredTrips.filter { $0.routePatternID == route.id }.count >= 3)
            }
            .sorted { left, right in
                if left.isFavorite != right.isFavorite { return left.isFavorite }
                let leftCount = filteredTrips.filter { $0.routePatternID == left.id }.count
                let rightCount = filteredTrips.filter { $0.routePatternID == right.id }.count
                if leftCount != rightCount { return leftCount > rightCount }
                return left.lastUsedAt > right.lastUsedAt
            }
            .prefix(5)
            .map { $0 }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Period", selection: $period) {
                        ForEach(StatsPeriod.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                if historyModel.overview.latestEventAt != nil || !days.isEmpty {
                    Section("Places") {
                        if let currentVisit {
                            CurrentPlaceCard(place: currentPlace, visit: currentVisit)
                        }
                        NavigationLink {
                            PlacesView(historyModel: historyModel)
                        } label: {
                            LabeledContent("Browse All Places", value: places.filter { !$0.isExcluded }.count.formatted())
                        }
                    }

                    Section("Overview") {
                        LabeledContent("Distance", value: distance.formattedDistance)
                        LabeledContent("Moving time", value: movingDuration.formattedDuration)
                        LabeledContent("Time at places", value: placeDuration.formattedDuration)
                        LabeledContent("Trips", value: filteredTrips.count.formatted())
                        LabeledContent("Tracked days", value: filteredDays.count.formatted())
                        if filteredDays.contains(where: { $0.completeness < 1 }) {
                            Label("Some days contain tracking gaps", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }

                    if !filteredDays.isEmpty {
                        Section("Daily Distance") {
                            Chart(filteredDays) { day in
                                BarMark(
                                    x: .value("Day", day.dayStart, unit: .day),
                                    y: .value("Distance", day.distanceMeters / 1_000)
                                )
                                .foregroundStyle(day.completeness < 1 ? .orange : .blue)
                                .accessibilityLabel(day.dayStart.formatted(date: .abbreviated, time: .omitted))
                                .accessibilityValue(day.distanceMeters.formattedDistance)
                            }
                            .chartYAxisLabel("Kilometers")
                            .chartScrollableAxes(.horizontal)
                            .chartXVisibleDomain(length: min(TimeInterval(filteredDays.count), 14) * 86_400)
                            .frame(minHeight: 220)
                        }
                    }

                    if !favoritePlaces.isEmpty {
                        Section("Top Places") {
                            Chart(favoritePlaces) { place in
                                BarMark(
                                    x: .value("Time", periodDuration(at: place.id) / 3_600),
                                    y: .value("Place", place.name)
                                )
                                .accessibilityLabel(place.name)
                                .accessibilityValue(periodDuration(at: place.id).formattedDuration)
                            }
                            .chartXAxisLabel("Hours")
                            .chartXScale(domain: .automatic(includesZero: true))
                            .frame(minHeight: max(Double(favoritePlaces.count) * 44, 180))

                            ForEach(favoritePlaces) { place in
                                NavigationLink {
                                    PlaceDetailView(place: place, historyModel: historyModel)
                                } label: {
                                    LabeledContent(place.name, value: periodDuration(at: place.id).formattedDuration)
                                }
                            }
                        }
                    }

                    Section("Movement") {
                        ForEach(MovementMode.allCases, id: \.self) { mode in
                            let modeTrips = filteredTrips.filter { $0.mode == mode }
                            if !modeTrips.isEmpty {
                                LabeledContent(mode.displayName, value: modeTrips.count.formatted())
                            }
                        }
                    }

                    if !favoriteRoutes.isEmpty {
                        Section("Favorite Routes") {
                            ForEach(favoriteRoutes) { route in
                                let origin = places.first { $0.id == route.originPlaceID }?.name ?? "Place"
                                let destination = places.first { $0.id == route.destinationPlaceID }?.name ?? "Place"
                                let periodTrips = filteredTrips.filter { $0.routePatternID == route.id }
                                NavigationLink {
                                    RoutePatternDetailView(
                                        route: route,
                                        originName: origin,
                                        destinationName: destination,
                                        trips: periodTrips,
                                        historyModel: historyModel
                                    )
                                } label: {
                                    VStack(alignment: .leading) {
                                        Text(route.name ?? "\(origin) ↔ \(destination)")
                                            .font(.headline)
                                        Text("\(periodTrips.count) trips · \((periodTrips.reduce(0) { $0 + $1.elapsedDuration } / Double(max(periodTrips.count, 1))).formattedDuration)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    Section {
                        ContentUnavailableView(
                            "No History Stats Yet",
                            systemImage: "chart.bar.xaxis",
                            description: Text("Enable Location History and move through the world to build private statistics.")
                        )
                    }
                    .listRowBackground(Color.clear)
                }

                Section("Exploration") {
                    LabeledContent("Cleared street cells", value: (explorationSummary?.exploredCellCount ?? 0).formatted())
                    if let latestUnlockDate = explorationSummary?.lastUnlockDate {
                        LabeledContent("Last unlock") { Text(latestUnlockDate, format: .dateTime.month().day().hour().minute()) }
                    }
                }
            }
            .navigationTitle("Stats")
            .task { await historyModel.refresh() }
        }
    }

    private func periodDuration(at placeID: UUID) -> TimeInterval {
        filteredVisits.filter { $0.placeID == placeID }.reduce(0) { result, visit in
            let start = max(visit.arrivalDate, periodStart)
            let end = min(visit.departureDate ?? .now, .now)
            return result + max(end.timeIntervalSince(start), 0)
        }
    }
}

private struct RoutePatternDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var allRoutes: [HistoryRoutePatternRecord]
    @Query(sort: \HistoryTripRecord.startedAt, order: .reverse) private var allTrips: [HistoryTripRecord]
    let route: HistoryRoutePatternRecord
    let originName: String
    let destinationName: String
    let trips: [HistoryTripRecord]
    let historyModel: HistoryModel
    @State private var name = ""
    @State private var isExcluded = false
    @State private var mergeTarget: HistoryRoutePatternRecord?

    var body: some View {
        Form {
            if points.count >= 2 {
                Section {
                    Map(initialPosition: mapPosition) {
                        MapPolyline(coordinates: points.map { $0.coordinate.locationCoordinate })
                            .stroke(.blue, lineWidth: 5)
                    }
                    .frame(minHeight: 220)
                    .clipShape(.rect(cornerRadius: 16))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Representative route from \(originName) to \(destinationName)")
                }
            }
            Section("Route") {
                TextField("Custom name", text: $name)
                Toggle(
                    "Favorite",
                    isOn: Binding(
                        get: { route.isFavorite },
                        set: { historyModel.setFavorite(routeID: route.id, isFavorite: $0) }
                    )
                )
                Toggle("Exclude from rankings", isOn: $isExcluded)
                Button("Save Changes", systemImage: "checkmark") {
                    Task {
                        if await historyModel.updateRoute(
                            id: route.id,
                            name: name.isEmpty ? nil : name,
                            isExcluded: isExcluded
                        ) { dismiss() }
                    }
                }
            }
            Section("Statistics") {
                LabeledContent("From", value: originName)
                LabeledContent("To", value: destinationName)
                LabeledContent("Trips", value: trips.count.formatted())
                LabeledContent("Average distance", value: (trips.reduce(0) { $0 + $1.distanceMeters } / Double(max(trips.count, 1))).formattedDistance)
                LabeledContent("Average duration", value: (trips.reduce(0) { $0 + $1.elapsedDuration } / Double(max(trips.count, 1))).formattedDuration)
            }
            Section("Corrections") {
                if allRoutes.contains(where: { $0.id != route.id }) {
                    Menu("Merge Into Another Route", systemImage: "arrow.triangle.merge") {
                        ForEach(allRoutes.filter { $0.id != route.id }) { target in
                            Button(target.name ?? "Route \(target.tripCount)") { mergeTarget = target }
                        }
                    }
                }
                ForEach(allTrips.filter { $0.routePatternID == route.id }) { trip in
                    Button("Split trip from \(trip.startedAt.formatted(date: .abbreviated, time: .shortened))", systemImage: "arrow.branch") {
                        Task { _ = await historyModel.splitTripFromRoute(tripID: trip.id) }
                    }
                }
            }
        }
        .navigationTitle(route.name ?? "Favorite Route")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            name = route.name ?? ""
            isExcluded = route.isExcluded
        }
        .confirmationDialog(
            "Merge this route?",
            isPresented: Binding(get: { mergeTarget != nil }, set: { if !$0 { mergeTarget = nil } }),
            presenting: mergeTarget
        ) { target in
            Button("Merge into \(target.name ?? "selected route")", role: .destructive) {
                Task {
                    if await historyModel.mergeRoutes(sourceID: route.id, destinationID: target.id) {
                        dismiss()
                    }
                }
            }
        }
    }

    private var points: [HistoryPoint] {
        (try? HistoryPointCodec.decode(route.representativeGeometry)) ?? []
    }

    private var mapPosition: MapCameraPosition {
        var rect = MKMapRect.null
        for point in points {
            let mapPoint = MKMapPoint(point.coordinate.locationCoordinate)
            rect = rect.union(MKMapRect(x: mapPoint.x, y: mapPoint.y, width: 1, height: 1))
        }
        guard !rect.isNull else { return .automatic }
        return .rect(rect.insetBy(dx: -max(rect.width * 0.15, 1_000), dy: -max(rect.height * 0.15, 1_000)))
    }
}

private enum StatsPeriod: String, CaseIterable, Identifiable {
    case week
    case month
    case year
    case all

    var id: String { rawValue }
    var title: String {
        switch self {
        case .week: "Week"
        case .month: "Month"
        case .year: "Year"
        case .all: "All"
        }
    }
}

#Preview {
    StatsView(historyModel: HistoryModel())
        .modelContainer(for: [
            ExplorationSummaryRecord.self,
            HistoryDailySummaryRecord.self,
            HistoryPlaceRecord.self,
            HistoryRoutePatternRecord.self,
            HistoryTripRecord.self,
            HistoryVisitRecord.self,
            PlaceSuggestionPreferenceRecord.self,
        ], inMemory: true)
}
