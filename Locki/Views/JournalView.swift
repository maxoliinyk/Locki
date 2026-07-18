//
//  JournalView.swift
//  Locki
//
//  Created by Max Oliinyk on 06.05.2026.
//

import MapKit
import SwiftData
import SwiftUI

struct JournalView: View {
    @Query(sort: \HistoryTripRecord.startedAt, order: .reverse) private var trips: [HistoryTripRecord]
    @Query(sort: \HistoryVisitRecord.arrivalDate, order: .reverse) private var visits: [HistoryVisitRecord]
    @Query private var places: [HistoryPlaceRecord]
    @Query private var chunks: [TrajectoryChunkRecord]
    @Query private var gaps: [HistoryGapRecord]

    let historyModel: HistoryModel
    @State private var selectedPeriod = HistoryPeriod.day
    @State private var anchorDate = Date.now
    @State private var pendingDeletion: JournalDeletion?
    @State private var showsDeletionError = false

    private var earliestHistoryDate: Date {
        [
            trips.map(\.startedAt).min(),
            visits.map(\.arrivalDate).min(),
            gaps.map(\.startedAt).min(),
        ]
        .compactMap { $0 }
        .min() ?? .now
    }

    private var selectedRange: HistoryDateRange {
        selectedPeriod.range(
            containing: anchorDate,
            earliestDate: earliestHistoryDate
        )
    }

    private var periodTrips: [HistoryTripRecord] {
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

    private var periodVisits: [HistoryVisitRecord] {
        visits.filter {
            !$0.isExcluded
                && JournalPresentation.overlaps(
                    start: $0.arrivalDate,
                    end: $0.departureDate,
                    range: selectedRange.interval
                )
        }
    }

    private var periodGaps: [HistoryGapRecord] {
        gaps.filter {
            JournalPresentation.overlaps(
                start: $0.startedAt,
                end: $0.endedAt,
                range: selectedRange.interval
            )
        }
    }

    private var timeline: [JournalTimelineItem] {
        let tripItems = periodTrips.map { JournalTimelineItem.trip($0) }
        let visitItems = periodVisits.map { JournalTimelineItem.visit($0) }
        let gapItems = periodGaps.map { JournalTimelineItem.gap($0) }
        return (tripItems + visitItems + gapItems).sorted {
            $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date
        }
    }

    private var timelineSections: [JournalTimelineSection] {
        let itemsByID = Dictionary(uniqueKeysWithValues: timeline.map { ($0.id, $0) })
        return JournalPresentation.dayGroups(timeline.map(\.descriptor)).map { group in
            JournalTimelineSection(
                group: group,
                items: group.itemIDs.compactMap { itemsByID[$0] }
            )
        }
    }

    private var mapRoutes: [JournalMapRoute] {
        let chunksByTripID = Dictionary(grouping: chunks, by: \.tripID)
        let routes = periodTrips
            .sorted { $0.startedAt < $1.startedAt }
            .map { trip in
                (chunksByTripID[trip.id] ?? [])
                    .sorted { $0.sequence < $1.sequence }
                    .flatMap(\.points)
            }
        return JournalPresentation.reducedRoutes(routes, pointLimit: mapPointLimit).map {
            JournalMapRoute(points: $0)
        }
    }

    private var mapPointLimit: Int {
        switch selectedPeriod {
        case .day: 2_500
        case .week: 2_500
        case .month: 2_000
        case .year: 1_500
        case .all: 1_000
        }
    }

    private var mapVisits: [HistoryVisitRecord] {
        let sortedVisits = periodVisits.sorted { $0.arrivalDate < $1.arrivalDate }
        return JournalPresentation.sampledIndices(count: sortedVisits.count, limit: 250).map {
            sortedVisits[$0]
        }
    }

    private var mapID: String {
        "\(selectedPeriod.id)-\(selectedRange.interval.start.timeIntervalSinceReferenceDate)"
    }

    var body: some View {
        NavigationStack {
            List {
                periodControls

                if !timeline.isEmpty {
                    if !periodTrips.isEmpty || !periodVisits.isEmpty {
                        Section {
                            JournalRangeMap(
                                routes: mapRoutes,
                                visits: mapVisits
                            )
                            .id(mapID)
                            .frame(minHeight: 220)
                            .clipShape(.rect(cornerRadius: 16))
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Map of routes and visits for \(selectedRange.title())")
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }

                    Section("Summary") {
                        LabeledContent(
                            "Distance",
                            value: periodTrips.reduce(0) { $0 + $1.distanceMeters }.formattedDistance
                        )
                        LabeledContent(
                            "Moving time",
                            value: periodTrips.reduce(0) { $0 + $1.movingDuration }.formattedDuration
                        )
                        LabeledContent("Visits", value: periodVisits.count.formatted())
                        LabeledContent("Trips", value: periodTrips.count.formatted())
                        if !periodGaps.isEmpty {
                            Label(
                                "History contains \(periodGaps.count) tracking gap\(periodGaps.count == 1 ? "" : "s")",
                                systemImage: "exclamationmark.triangle"
                            )
                                .foregroundStyle(.orange)
                        }
                    }

                    if selectedPeriod == .day {
                        Section("Timeline") {
                            ForEach(timeline) { item in
                                timelineRow(item)
                            }
                        }
                    } else {
                        ForEach(timelineSections) { section in
                            Section {
                                ForEach(section.items) { item in
                                    timelineRow(item)
                                }
                            } header: {
                                Text(section.group.title())
                                    .accessibilityAddTraits(.isHeader)
                            }
                        }
                    }
                } else {
                    Section {
                        ContentUnavailableView(
                            historyModel.isEnabled ? "No History in This Period" : "Location History Is Off",
                            systemImage: historyModel.isEnabled ? "calendar.badge.clock" : "location.slash",
                            description: Text(
                                historyModel.isEnabled
                                    ? "Trips and visits will appear when Locki captures reliable movement."
                                    : "Enable Location History in Settings to build a private timeline."
                            )
                        )
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Journal")
            .task { await historyModel.refresh() }
        }
        .confirmationDialog(
            pendingDeletion?.title ?? "Delete history item?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { deletion in
            Button(deletion.actionTitle, role: .destructive) {
                Task {
                    if !(await performDeletion(deletion)) {
                        showsDeletionError = true
                    }
                }
            }
        } message: { deletion in
            Text(deletion.message)
        }
        .alert("Couldn’t Delete History", isPresented: $showsDeletionError) {
            Button("OK") {}
        } message: {
            Text("Locki couldn’t save this change. Your history item may still be present.")
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

    @ViewBuilder
    private func timelineRow(_ item: JournalTimelineItem) -> some View {
        switch item {
        case .trip(let trip):
            NavigationLink {
                TripDetailView(trip: trip, points: chunks.filter { $0.tripID == trip.id }.flatMap(\.points))
            } label: {
                JournalRow(
                    icon: trip.mode.systemImage,
                    title: trip.mode.displayName,
                    subtitle: "\(trip.distanceMeters.formattedDistance) · \(trip.movingDuration.formattedDuration)",
                    date: trip.startedAt,
                    timeZoneIdentifier: trip.startTimeZoneIdentifier,
                    warning: trip.completeness < 1 ? "Incomplete" : nil
                )
            }
            .swipeActions {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    pendingDeletion = .trip(id: trip.id)
                }
            }
            .accessibilityAction(named: "Delete trip") {
                pendingDeletion = .trip(id: trip.id)
            }

        case .visit(let visit):
            let place = places.first { $0.id == visit.placeID }
            NavigationLink {
                if let place { PlaceDetailView(place: place, historyModel: historyModel) }
                else { Text("This visit has no place classification.") }
            } label: {
                JournalRow(
                    icon: "mappin.circle.fill",
                    title: place?.name ?? "Unclassified place",
                    subtitle: visit.duration.formattedDuration,
                    date: visit.arrivalDate,
                    timeZoneIdentifier: visit.timeZoneIdentifier,
                    warning: visit.departureDate == nil
                        ? "Still here"
                        : visit.quality < 0.5 ? "Estimated" : nil
                )
            }
            .swipeActions {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    pendingDeletion = .visit(id: visit.id)
                }
            }
            .accessibilityAction(named: "Delete visit") {
                pendingDeletion = .visit(id: visit.id)
            }

        case .gap(let gap):
            JournalRow(
                icon: "exclamationmark.triangle.fill",
                title: "Tracking gap",
                subtitle: gap.reason.displayName,
                date: gap.startedAt,
                timeZoneIdentifier: TimeZone.current.identifier,
                warning: gap.endedAt == nil ? "Ongoing" : nil
            )
            .foregroundStyle(.orange)
        }
    }

    private func performDeletion(_ deletion: JournalDeletion) async -> Bool {
        switch deletion {
        case .trip(let id): await historyModel.deleteTrip(id: id)
        case .visit(let id): await historyModel.deleteVisit(id: id)
        }
    }
}

private enum JournalDeletion {
    case trip(id: UUID)
    case visit(id: UUID)

    var title: String {
        switch self {
        case .trip: "Delete this trip?"
        case .visit: "Delete this visit?"
        }
    }

    var actionTitle: String {
        switch self {
        case .trip: "Delete Trip"
        case .visit: "Delete Visit"
        }
    }

    var message: String {
        switch self {
        case .trip: "This permanently removes the trip and its saved route points. Related statistics will be recalculated."
        case .visit: "This permanently removes the visit. Related place totals and statistics will be recalculated."
        }
    }
}

private enum JournalTimelineItem: Identifiable {
    case trip(HistoryTripRecord)
    case visit(HistoryVisitRecord)
    case gap(HistoryGapRecord)

    var id: String {
        switch self {
        case .trip(let value): "trip-\(value.id)"
        case .visit(let value): "visit-\(value.id)"
        case .gap(let value): "gap-\(value.id)"
        }
    }

    var date: Date {
        switch self {
        case .trip(let value): value.startedAt
        case .visit(let value): value.arrivalDate
        case .gap(let value): value.startedAt
        }
    }

    var timeZoneIdentifier: String {
        switch self {
        case .trip(let value): value.startTimeZoneIdentifier
        case .visit(let value): value.timeZoneIdentifier
        case .gap: TimeZone.current.identifier
        }
    }

    var descriptor: JournalTimelineDescriptor {
        JournalTimelineDescriptor(id: id, date: date, timeZoneIdentifier: timeZoneIdentifier)
    }
}

private struct JournalTimelineSection: Identifiable {
    let group: JournalDayGroup
    let items: [JournalTimelineItem]

    var id: String { group.id }
}

private struct JournalRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let date: Date
    let timeZoneIdentifier: String
    let warning: String?

    var body: some View {
        Label {
            VStack(alignment: .leading) {
                HStack {
                    Text(title).font(.headline)
                    if let warning {
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                Text(formattedTime)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon)
        }
        .accessibilityElement(children: .combine)
    }

    private var formattedTime: String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private struct JournalMapRoute: Identifiable {
    let id: String
    let coordinates: [CLLocationCoordinate2D]

    init(points: [HistoryPoint]) {
        let first = points.first
        let last = points.last
        id = [
            first?.timestampSeconds ?? 0,
            Int64(first?.latitudeE5 ?? 0),
            Int64(first?.longitudeE5 ?? 0),
            last?.timestampSeconds ?? 0,
            Int64(last?.latitudeE5 ?? 0),
            Int64(last?.longitudeE5 ?? 0),
            Int64(points.count),
        ]
        .map(String.init)
        .joined(separator: "-")
        coordinates = points.map { $0.coordinate.locationCoordinate }
    }
}

private struct JournalRangeMap: View {
    let routes: [JournalMapRoute]
    let visits: [HistoryVisitRecord]

    var body: some View {
        Map(initialPosition: cameraPosition) {
            ForEach(routes) { route in
                MapPolyline(coordinates: route.coordinates)
                    .stroke(.blue, lineWidth: 5)
            }
            ForEach(visits) { visit in
                Marker(
                    "Visit",
                    systemImage: "mappin.circle.fill",
                    coordinate: CLLocationCoordinate2D(latitude: visit.latitude, longitude: visit.longitude)
                )
            }
        }
        .mapStyle(.standard)
        .mapControls { MapCompass(); MapScaleView() }
    }

    private var cameraPosition: MapCameraPosition {
        let coordinates = routes.flatMap(\.coordinates) + visits.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        guard !coordinates.isEmpty else { return .automatic }
        var rect = MKMapRect.null
        for coordinate in coordinates {
            let point = MKMapPoint(coordinate)
            rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 1, height: 1))
        }
        return .rect(rect.insetBy(dx: -max(rect.width * 0.15, 1_000), dy: -max(rect.height * 0.15, 1_000)))
    }
}

private struct TripDetailView: View {
    let trip: HistoryTripRecord
    let points: [HistoryPoint]

    var body: some View {
        List {
            Section("Trip") {
                LabeledContent("Distance", value: trip.distanceMeters.formattedDistance)
                LabeledContent("Moving time", value: trip.movingDuration.formattedDuration)
                LabeledContent("Average speed", value: trip.averageMovingSpeedMetersPerSecond.formattedSpeed)
                LabeledContent("Peak speed", value: trip.peakSpeedMetersPerSecond.formattedSpeed)
                LabeledContent("Mode", value: trip.mode.displayName)
                LabeledContent("Confidence", value: trip.modeConfidence, format: .percent.precision(.fractionLength(0)))
                LabeledContent("Completeness", value: trip.completeness, format: .percent.precision(.fractionLength(0)))
            }
            Section("Time") {
                LabeledContent("Started") { Text(trip.startedAt, format: .dateTime) }
                if let endedAt = trip.endedAt { LabeledContent("Ended") { Text(endedAt, format: .dateTime) } }
            }
        }
        .navigationTitle("Trip")
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension Double {
    var formattedSpeed: String {
        Measurement(value: self, unit: UnitSpeed.metersPerSecond).formatted(.measurement(width: .abbreviated))
    }
}

extension HistoryVisitRecord {
    var duration: TimeInterval { max((departureDate ?? .now).timeIntervalSince(arrivalDate), 0) }
}

extension MovementMode {
    var displayName: String {
        switch self {
        case .walking: "Walking"
        case .cycling: "Cycling"
        case .motorized: "Motorized"
        case .unknown: "Unclassified trip"
        }
    }

    var systemImage: String {
        switch self {
        case .walking: "figure.walk"
        case .cycling: "bicycle"
        case .motorized: "car"
        case .unknown: "point.topleft.down.to.point.bottomright.curvepath"
        }
    }
}

extension HistoryGapReason {
    var displayName: String {
        switch self {
        case .authorization: "Location permission was unavailable"
        case .reducedAccuracy: "Precise Location was unavailable"
        case .discontinuity: "Reliable updates were interrupted"
        case .disabled: "Location History was disabled"
        case .persistence: "History could not be saved"
        case .unavailable: "Location was unavailable"
        }
    }
}

#Preview {
    JournalView(historyModel: HistoryModel())
        .modelContainer(for: [
            HistoryTripRecord.self,
            HistoryVisitRecord.self,
            HistoryPlaceRecord.self,
            TrajectoryChunkRecord.self,
            HistoryGapRecord.self,
        ], inMemory: true)
}
