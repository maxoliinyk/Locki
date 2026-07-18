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
    @State private var selectedPeriod = HistoryPeriod.month
    @State private var anchorDate = Date.now

    private var explorationSummary: ExplorationSummaryRecord? {
        explorationSummaries.first { $0.key == "primary" }
    }

    private var earliestHistoryDate: Date {
        [days.map(\.dayStart).min(), trips.map(\.startedAt).min(), visits.map(\.arrivalDate).min()]
            .compactMap { $0 }
            .min() ?? .now
    }

    private var selectedRange: HistoryDateRange {
        selectedPeriod.range(containing: anchorDate, earliestDate: earliestHistoryDate)
    }

    private var daySnapshots: [StatsDaySnapshot] {
        days.map {
            StatsDaySnapshot(
                dayStart: $0.dayStart,
                distanceMeters: $0.distanceMeters,
                movingDuration: $0.movingDuration,
                placeDuration: $0.placeDuration,
                tripCount: $0.tripCount,
                visitCount: $0.visitCount,
                completeness: $0.completeness
            )
        }
    }

    private var filteredDays: [StatsDaySnapshot] {
        StatsPresentation.days(daySnapshots, in: selectedRange.interval)
    }

    private var overview: StatsOverview {
        StatsPresentation.overview(days: filteredDays)
    }

    private var chartGranularity: StatsChartGranularity? {
        StatsPresentation.chartGranularity(for: selectedPeriod, range: selectedRange.interval)
    }

    private var chartBuckets: [StatsDistanceBucket] {
        guard let chartGranularity else { return [] }
        return StatsPresentation.distanceBuckets(days: filteredDays, granularity: chartGranularity)
    }

    private var filteredTrips: [HistoryTripRecord] {
        trips.filter {
            !$0.isExcluded
                && ($0.distanceMeters >= HistoryConfiguration.standard.minimumTripDistanceMeters
                    || $0.elapsedDuration >= HistoryConfiguration.standard.minimumTripDuration)
                && JournalPresentation.overlaps(
                    start: $0.startedAt,
                    end: $0.endedAt,
                    range: selectedRange.interval
                )
        }
    }
    private var filteredVisits: [HistoryVisitRecord] {
        visits.filter {
            !$0.isExcluded
                && JournalPresentation.overlaps(
                    start: $0.arrivalDate,
                    end: $0.departureDate,
                    range: selectedRange.interval
                )
        }
    }

    private var favoritePlaces: [HistoryPlaceRecord] {
        places
            .filter { place in
                let placeVisits = filteredVisits.filter { $0.placeID == place.id }
                let visitDays = Set(placeVisits.map { Calendar.current.startOfDay(for: $0.arrivalDate) }).count
                let duration = periodDuration(at: place.id)
                return !place.isExcluded
                    && (place.isFavorite
                        || (placeVisits.count >= FrequentPlaceRanker.minimumVisitCount
                            && visitDays >= FrequentPlaceRanker.minimumDistinctDayCount
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
                periodControls

                if !filteredDays.isEmpty {
                    Section("Overview") {
                        LabeledContent("Distance", value: overview.distanceMeters.formattedDistance)
                        LabeledContent("Moving time", value: overview.movingDuration.formattedDuration)
                        LabeledContent("Time at places", value: overview.placeDuration.formattedDuration)
                        LabeledContent("Trips", value: overview.tripCount.formatted())
                        if selectedPeriod == .day {
                            LabeledContent("Visits", value: overview.visitCount.formatted())
                        } else {
                            LabeledContent("Tracked days", value: overview.trackedDayCount.formatted())
                        }
                        if overview.containsIncompleteHistory {
                            Label("Some days contain tracking gaps", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }

                    if let chartGranularity, !chartBuckets.isEmpty {
                        Section(chartGranularity.title) {
                            Chart(chartBuckets) { bucket in
                                BarMark(
                                    x: .value("Date", bucket.start),
                                    y: .value("Distance", bucket.distanceMeters / 1_000)
                                )
                                .foregroundStyle(bucket.completeness < 1 ? .orange : .blue)
                                .annotation(position: .top) {
                                    if bucket.completeness < 1 {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                            .accessibilityHidden(true)
                                    }
                                }
                                .accessibilityLabel(chartDateLabel(bucket.start))
                                .accessibilityValue(
                                    bucket.completeness < 1
                                        ? "\(bucket.distanceMeters.formattedDistance), incomplete due to tracking gaps"
                                        : "\(bucket.distanceMeters.formattedDistance), complete"
                                )
                            }
                            .chartYAxisLabel("Kilometers")
                            .chartYScale(domain: .automatic(includesZero: true))
                            .chartXAxis {
                                AxisMarks(values: .automatic(desiredCount: 6)) { value in
                                    AxisGridLine()
                                    AxisTick()
                                    AxisValueLabel {
                                        if let date = value.as(Date.self) {
                                            Text(chartDateLabel(date))
                                        }
                                    }
                                }
                            }
                            .frame(minHeight: 220)
                            Text("A warning symbol marks days with incomplete history.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
                            historyModel.isEnabled ? "No Stats in This Period" : "Location History Is Off",
                            systemImage: "chart.bar.xaxis",
                            description: Text(
                                historyModel.isEnabled
                                    ? "Choose another period or keep exploring to build private statistics."
                                    : "Enable Location History in Settings to build private statistics."
                            )
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

    private var periodControls: some View {
        Section {
            Picker("Period", selection: $selectedPeriod) {
                ForEach(HistoryPeriod.allCases) { period in
                    Text(period.title).tag(period)
                }
            }
            .pickerStyle(.menu)

            if selectedPeriod != .all {
                DatePicker("Date", selection: $anchorDate, in: ...Date.now, displayedComponents: .date)
            }

            if selectedPeriod == .all {
                Text(selectedRange.title())
                    .frame(maxWidth: .infinity)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
            } else {
                HStack {
                    Button("Previous \(selectedPeriod.title.lowercased())", systemImage: "chevron.left") {
                        anchorDate = selectedPeriod.date(byAdvancing: anchorDate, value: -1)
                    }
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
                    .buttonStyle(.borderless)

                    Spacer(minLength: 8)

                    Text(selectedRange.title())
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)

                    Spacer(minLength: 8)

                    Button("Next \(selectedPeriod.title.lowercased())", systemImage: "chevron.right") {
                        anchorDate = selectedPeriod.date(byAdvancing: anchorDate, value: 1)
                    }
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
                    .buttonStyle(.borderless)
                    .disabled(!selectedPeriod.canAdvance(from: anchorDate))
                }
            }
        }
    }

    private func chartDateLabel(_ date: Date) -> String {
        switch chartGranularity {
        case .day:
            date.formatted(.dateTime.day().month(.abbreviated))
        case .month:
            selectedPeriod == .all
                ? date.formatted(.dateTime.month(.abbreviated).year())
                : date.formatted(.dateTime.month(.abbreviated))
        case .year:
            date.formatted(.dateTime.year())
        case nil:
            date.formatted(date: .abbreviated, time: .omitted)
        }
    }

    private func periodDuration(at placeID: UUID) -> TimeInterval {
        filteredVisits.filter { $0.placeID == placeID }.reduce(0) { result, visit in
            let start = max(visit.arrivalDate, selectedRange.interval.start)
            let end = min(visit.departureDate ?? .now, selectedRange.interval.end, .now)
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
