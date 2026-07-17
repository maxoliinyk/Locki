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
    @State private var selectedDay = Calendar.current.startOfDay(for: .now)

    private var dayInterval: DateInterval {
        let calendar = Calendar.current
        return DateInterval(
            start: selectedDay,
            end: calendar.date(byAdding: .day, value: 1, to: selectedDay) ?? selectedDay.addingTimeInterval(86_400)
        )
    }

    private var dayTrips: [HistoryTripRecord] {
        trips.filter {
            !$0.isExcluded
                && ($0.distanceMeters >= HistoryConfiguration.standard.minimumTripDistanceMeters
                    || $0.elapsedDuration >= HistoryConfiguration.standard.minimumTripDuration)
                && $0.startedAt < dayInterval.end
                && ($0.endedAt ?? .distantFuture) >= dayInterval.start
        }
    }

    private var dayVisits: [HistoryVisitRecord] {
        visits.filter {
            !$0.isExcluded
                && $0.arrivalDate < dayInterval.end
                && ($0.departureDate ?? .distantFuture) >= dayInterval.start
        }
    }

    private var dayGaps: [HistoryGapRecord] {
        gaps.filter { $0.startedAt < dayInterval.end && ($0.endedAt ?? .distantFuture) >= dayInterval.start }
    }

    private var timeline: [JournalTimelineItem] {
        let tripItems = dayTrips.map { JournalTimelineItem.trip($0) }
        let visitItems = dayVisits.map { JournalTimelineItem.visit($0) }
        let gapItems = dayGaps.map { JournalTimelineItem.gap($0) }
        return (tripItems + visitItems + gapItems).sorted { $0.date < $1.date }
    }

    var body: some View {
        NavigationStack {
            List {
                dayPicker

                if !timeline.isEmpty {
                    if !dayTrips.isEmpty || !dayVisits.isEmpty {
                        Section {
                            JournalDayMap(
                                trips: dayTrips,
                                visits: dayVisits,
                                chunks: chunks
                            )
                            .frame(minHeight: 220)
                            .clipShape(.rect(cornerRadius: 16))
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Map of the selected day's routes and visits")
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }

                    Section("Day Summary") {
                        LabeledContent("Distance", value: dayTrips.reduce(0) { $0 + $1.distanceMeters }.formattedDistance)
                        LabeledContent("Moving time", value: dayTrips.reduce(0) { $0 + $1.movingDuration }.formattedDuration)
                        LabeledContent("Visits", value: dayVisits.count.formatted())
                        if !dayGaps.isEmpty {
                            Label("History contains \(dayGaps.count) tracking gap\(dayGaps.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }

                    Section("Timeline") {
                        ForEach(timeline) { item in
                            timelineRow(item)
                        }
                    }
                } else {
                    Section {
                        ContentUnavailableView(
                            historyModel.isEnabled ? "No History This Day" : "Location History Is Off",
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
    }

    private var dayPicker: some View {
        Section {
            HStack {
                Button("Previous day", systemImage: "chevron.left") {
                    selectedDay = Calendar.current.date(byAdding: .day, value: -1, to: selectedDay) ?? selectedDay
                }
                .labelStyle(.iconOnly)

                Spacer()
                DatePicker("Day", selection: $selectedDay, in: ...Date.now, displayedComponents: .date)
                    .labelsHidden()
                    .accessibilityLabel("Journal day")
                Spacer()

                Button("Next day", systemImage: "chevron.right") {
                    selectedDay = min(
                        Calendar.current.date(byAdding: .day, value: 1, to: selectedDay) ?? selectedDay,
                        Calendar.current.startOfDay(for: .now)
                    )
                }
                .labelStyle(.iconOnly)
                .disabled(Calendar.current.isDateInToday(selectedDay))
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
                    warning: trip.completeness < 1 ? "Incomplete" : nil
                )
            }
            .swipeActions {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    historyModel.deleteTrip(id: trip.id)
                }
            }
            .accessibilityAction(named: "Delete trip") { historyModel.deleteTrip(id: trip.id) }

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
                    warning: visit.departureDate == nil ? "Still here" : nil
                )
            }
            .swipeActions {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    historyModel.deleteVisit(id: visit.id)
                }
            }
            .accessibilityAction(named: "Delete visit") { historyModel.deleteVisit(id: visit.id) }

        case .gap(let gap):
            JournalRow(
                icon: "exclamationmark.triangle.fill",
                title: "Tracking gap",
                subtitle: gap.reason.displayName,
                date: gap.startedAt,
                warning: gap.endedAt == nil ? "Ongoing" : nil
            )
            .foregroundStyle(.orange)
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
}

private struct JournalRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let date: Date
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
                Text(date, format: .dateTime.hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct JournalDayMap: View {
    let trips: [HistoryTripRecord]
    let visits: [HistoryVisitRecord]
    let chunks: [TrajectoryChunkRecord]

    var body: some View {
        Map(initialPosition: cameraPosition) {
            ForEach(trips) { trip in
                let coordinates = chunks
                    .filter { $0.tripID == trip.id }
                    .sorted { $0.sequence < $1.sequence }
                    .flatMap(\.points)
                    .map { $0.coordinate.locationCoordinate }
                if coordinates.count >= 2 {
                    MapPolyline(coordinates: coordinates)
                        .stroke(.blue, lineWidth: 5)
                }
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
        let coordinates = trips.flatMap { trip in
            chunks.filter { $0.tripID == trip.id }.flatMap(\.points).map { $0.coordinate.locationCoordinate }
        } + visits.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
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

extension TimeInterval {
    var formattedDuration: String {
        Duration.seconds(self).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}

extension Double {
    var formattedDistance: String {
        Measurement(value: self, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated))
    }

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
