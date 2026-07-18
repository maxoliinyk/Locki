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
    @State private var showsDismissedGaps = false
    @State private var isSelectingGaps = false
    @State private var selectedGapIDs = Set<UUID>()
    @State private var pendingBatchAction: HistoryGapBatchAction?
    @State private var batchFeedback: JournalBatchFeedback?

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

    private var periodGapRecords: [HistoryGapRecord] {
        gaps.filter {
            JournalPresentation.overlaps(
                start: $0.startedAt,
                end: $0.endedAt,
                range: selectedRange.interval
            )
        }
    }

    private var periodGaps: [HistoryGapRecord] {
        periodGapRecords.filter { $0.resolution != .noMovement }
    }

    private var displayedGaps: [HistoryGapRecord] {
        periodGaps.filter { showsDismissedGaps || $0.resolution != .dismissed }
    }

    private var dismissedGapCount: Int {
        periodGaps.filter { $0.resolution == .dismissed }.count
    }

    private var hasPeriodHistory: Bool {
        !periodTrips.isEmpty || !periodVisits.isEmpty || !periodGaps.isEmpty
    }

    private var timeline: [JournalTimelineItem] {
        let gapItems = displayedGaps.map { JournalTimelineItem.gap($0) }
        guard !isSelectingGaps else {
            return gapItems.sorted {
                $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date
            }
        }
        let tripItems = periodTrips.map { JournalTimelineItem.trip($0) }
        let visitItems = periodVisits.map { JournalTimelineItem.visit($0) }
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

    private var estimatedMapRoutes: [JournalMapRoute] {
        periodGaps.compactMap { gap in
            guard gap.resolution == .confirmedRoute, gap.estimatedRoute.count >= 2 else { return nil }
            return JournalMapRoute(gapID: gap.id, coordinates: gap.estimatedRoute)
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

                if hasPeriodHistory {
                    if !isSelectingGaps && (!periodTrips.isEmpty || !periodVisits.isEmpty) {
                        Section {
                            JournalRangeMap(
                                routes: mapRoutes,
                                estimatedRoutes: estimatedMapRoutes,
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
                                "History contains \(periodGaps.count) incomplete interval\(periodGaps.count == 1 ? "" : "s")",
                                systemImage: "exclamationmark.triangle"
                            )
                                .foregroundStyle(.orange)
                        }
                        if dismissedGapCount > 0 {
                            Button(showsDismissedGaps ? "Hide Dismissed Gaps" : "Show \(dismissedGapCount) Dismissed Gap\(dismissedGapCount == 1 ? "" : "s")") {
                                showsDismissedGaps.toggle()
                            }
                        }
                    }

                    if timeline.isEmpty {
                        Section {
                            ContentUnavailableView(
                                "Dismissed Gaps Hidden",
                                systemImage: "eye.slash",
                                description: Text("Show dismissed gaps in Summary to select or restore them.")
                            )
                        }
                        .listRowBackground(Color.clear)
                    } else if selectedPeriod == .day {
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
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isSelectingGaps { gapBatchActionBar }
            }
            .navigationTitle("Journal")
            .toolbar { gapSelectionToolbar }
            .task { await historyModel.refresh() }
            .onChange(of: mapID) { _, _ in endGapSelection() }
            .onChange(of: showsDismissedGaps) { _, _ in
                selectedGapIDs.formIntersection(displayedGaps.map(\.id))
            }
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
        .confirmationDialog(
            batchConfirmationTitle,
            isPresented: Binding(
                get: { pendingBatchAction != nil },
                set: { if !$0 { pendingBatchAction = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingBatchAction
        ) { action in
            Button(action.title, role: action == .dismiss ? .destructive : nil) {
                Task { await performBatchAction(action) }
            }
        } message: { action in
            Text(action.confirmationMessage)
        }
        .alert("Couldn’t Delete History", isPresented: $showsDeletionError) {
            Button("OK") {}
        } message: {
            Text("Locki couldn’t save this change. Your history item may still be present.")
        }
        .alert(item: $batchFeedback) { feedback in
            Alert(
                title: Text(feedback.title),
                message: Text(feedback.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    @ToolbarContentBuilder
    private var gapSelectionToolbar: some ToolbarContent {
        if !displayedGaps.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                Button(
                    isSelectingGaps ? "Done" : "Select Gaps",
                    systemImage: isSelectingGaps ? "checkmark" : "checklist"
                ) {
                    if isSelectingGaps { endGapSelection() }
                    else { isSelectingGaps = true }
                }
            }
        }

        if isSelectingGaps {
            ToolbarItem(placement: .topBarLeading) {
                Button(allDisplayedGapsSelected ? "Deselect All" : "Select All") {
                    if allDisplayedGapsSelected { selectedGapIDs.removeAll() }
                    else { selectedGapIDs = Set(displayedGaps.map(\.id)) }
                }
                .disabled(displayedGaps.isEmpty)
            }
        }
    }

    private var gapBatchActionBar: some View {
        VStack {
            Text("\(selectedGapIDs.count) gap\(selectedGapIDs.count == 1 ? "" : "s") selected")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            ViewThatFits(in: .horizontal) {
                HStack {
                    batchActionButton(.noMovement)
                    batchActionButton(.dismiss)
                    if eligibleSelectedGapCount(for: .restore) > 0 {
                        batchActionButton(.restore)
                    }
                }
                VStack {
                    batchActionButton(.noMovement)
                    batchActionButton(.dismiss)
                    if eligibleSelectedGapCount(for: .restore) > 0 {
                        batchActionButton(.restore)
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
    }

    private func batchActionButton(_ action: HistoryGapBatchAction) -> some View {
        let eligibleCount = eligibleSelectedGapCount(for: action)
        return Button {
            pendingBatchAction = action
        } label: {
            Label(
                eligibleCount == selectedGapIDs.count
                    ? action.shortTitle
                    : "\(action.shortTitle) (\(eligibleCount))",
                systemImage: action.systemImage
            )
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(action == .dismiss ? .red : .accentColor)
        .disabled(eligibleCount == 0)
        .accessibilityLabel("\(action.title), \(eligibleCount) eligible gaps")
    }

    private var batchConfirmationTitle: String {
        guard let pendingBatchAction else { return "Update selected gaps?" }
        return pendingBatchAction.confirmationTitle(
            count: eligibleSelectedGapCount(for: pendingBatchAction)
        )
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
            if isSelectingGaps {
                Button {
                    toggleGapSelection(gap.id)
                } label: {
                    HStack {
                        Image(systemName: selectedGapIDs.contains(gap.id) ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(selectedGapIDs.contains(gap.id) ? Color.accentColor : Color.secondary)
                            .accessibilityHidden(true)
                        gapRow(gap)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Select \(gap.resolution.title) at \(gap.startedAt.formatted(date: .abbreviated, time: .shortened))")
                .accessibilityValue(selectedGapIDs.contains(gap.id) ? "Selected" : "Not selected")
                .accessibilityHint("Adds or removes this gap from the batch")
            } else {
                NavigationLink {
                    GapDetailView(gapID: gap.id, historyModel: historyModel)
                } label: {
                    gapRow(gap)
                }
            }
        }
    }

    private func gapRow(_ gap: HistoryGapRecord) -> some View {
        JournalRow(
            icon: gap.resolution == .confirmedRoute
                ? "point.topleft.down.to.point.bottomright.curvepath"
                : "exclamationmark.triangle.fill",
            title: gap.resolution.title,
            subtitle: gap.journalSubtitle,
            date: gap.startedAt,
            timeZoneIdentifier: TimeZone.current.identifier,
            warning: gap.endedAt == nil ? "Ongoing" : nil
        )
    }

    private var allDisplayedGapsSelected: Bool {
        !displayedGaps.isEmpty && displayedGaps.allSatisfy { selectedGapIDs.contains($0.id) }
    }

    private func toggleGapSelection(_ id: UUID) {
        if selectedGapIDs.contains(id) { selectedGapIDs.remove(id) }
        else { selectedGapIDs.insert(id) }
    }

    private func endGapSelection() {
        isSelectingGaps = false
        selectedGapIDs.removeAll()
        pendingBatchAction = nil
    }

    private func eligibleSelectedGapCount(for action: HistoryGapBatchAction) -> Int {
        periodGapRecords.filter { gap in
            selectedGapIDs.contains(gap.id) && action.canApply(to: gap)
        }.count
    }

    private func performBatchAction(_ action: HistoryGapBatchAction) async {
        let selectedIDs = selectedGapIDs
        guard let result = await historyModel.applyGapBatch(ids: selectedIDs, action: action) else {
            batchFeedback = .saveFailure
            return
        }
        selectedGapIDs.subtract(result.appliedIDs)
        batchFeedback = JournalBatchFeedback(action: action, result: result)
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

private struct JournalBatchFeedback: Identifiable {
    let id = UUID()
    let title: String
    let message: String

    init(action: HistoryGapBatchAction, result: HistoryGapBatchResult) {
        title = result.appliedCount == 0
            ? "No Gaps Changed"
            : "Updated \(result.appliedCount) Gap\(result.appliedCount == 1 ? "" : "s")"
        if result.skippedCount > 0 {
            message = "\(result.skippedCount) selected gap\(result.skippedCount == 1 ? " was" : "s were") skipped because \(action.skippedReason)."
        } else {
            message = action.successMessage
        }
    }

    private init(title: String, message: String) {
        self.title = title
        self.message = message
    }

    static let saveFailure = JournalBatchFeedback(
        title: "Couldn’t Update Gaps",
        message: "Locki couldn’t save the batch change. The selected gaps may be unchanged."
    )
}

nonisolated private extension HistoryGapBatchAction {
    var title: String {
        switch self {
        case .noMovement: "Mark as No Movement"
        case .dismiss: "Dismiss from Journal"
        case .restore: "Restore to Unresolved"
        }
    }

    var systemImage: String {
        switch self {
        case .noMovement: "figure.stand"
        case .dismiss: "eye.slash"
        case .restore: "arrow.uturn.backward"
        }
    }

    var confirmationMessage: String {
        switch self {
        case .noMovement:
            "Only selected, unresolved movement gaps will be marked. Other gap types and existing resolutions stay unchanged."
        case .dismiss:
            "Only selected, unresolved gaps will be hidden. The missing intervals remain in completeness calculations."
        case .restore:
            "Selected resolutions, dismissals, and estimated routes will be removed. The gaps return to unresolved."
        }
    }

    var successMessage: String {
        switch self {
        case .noMovement: "The selected intervals no longer appear as gaps or reduce history completeness."
        case .dismiss: "The selected gaps are hidden but still count as incomplete history."
        case .restore: "The selected gaps are unresolved again."
        }
    }

    var skippedReason: String {
        switch self {
        case .noMovement: "it was not an unresolved movement gap"
        case .dismiss: "it was already resolved or dismissed"
        case .restore: "it was already unresolved"
        }
    }

    var shortTitle: String {
        switch self {
        case .noMovement: "No Movement"
        case .dismiss: "Dismiss"
        case .restore: "Restore"
        }
    }

    func confirmationTitle(count: Int) -> String {
        "\(title) for \(count) Gap\(count == 1 ? "" : "s")?"
    }
}

@MainActor
private extension HistoryGapBatchAction {
    func canApply(to gap: HistoryGapRecord) -> Bool {
        switch self {
        case .noMovement:
            gap.reason == .discontinuity && gap.resolution == .unresolved
        case .dismiss:
            gap.resolution == .unresolved
        case .restore:
            gap.resolution != .unresolved
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

    init(gapID: UUID, coordinates: [GeoCoordinate]) {
        id = "estimated-\(gapID.uuidString)"
        self.coordinates = coordinates.map(\.locationCoordinate)
    }
}

private struct JournalRangeMap: View {
    let routes: [JournalMapRoute]
    let estimatedRoutes: [JournalMapRoute]
    let visits: [HistoryVisitRecord]

    var body: some View {
        Map(initialPosition: cameraPosition) {
            ForEach(routes) { route in
                MapPolyline(coordinates: route.coordinates)
                    .stroke(.blue, lineWidth: 5)
            }
            ForEach(estimatedRoutes) { route in
                MapPolyline(coordinates: route.coordinates)
                    .stroke(.orange, style: StrokeStyle(lineWidth: 5, dash: [8, 6]))
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
        let coordinates = (routes + estimatedRoutes).flatMap(\.coordinates) + visits.map {
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

@MainActor
private extension HistoryGapRecord {
    var journalSubtitle: String {
        let diagnosis = (self.diagnosis ?? reason.defaultDiagnosis).displayName
        guard let endedAt else { return diagnosis }
        return "\(diagnosis) · \(max(endedAt.timeIntervalSince(startedAt), 0).formattedDuration)"
    }
}

nonisolated extension HistoryGapResolution {
    var title: String {
        switch self {
        case .unresolved: "Tracking gap"
        case .dismissed: "Dismissed gap"
        case .noMovement: "No movement confirmed"
        case .confirmedRoute: "Estimated route"
        }
    }
}

nonisolated extension HistoryGapDiagnosis {
    var displayName: String {
        switch self {
        case .prolongedUpdateInterval: "No reliable update arrived for an extended period"
        case .implausibleLocationJump: "The next location was too far away to connect reliably"
        case .permissionUnavailable: "Location permission was unavailable"
        case .preciseLocationUnavailable: "Precise Location was unavailable"
        case .historyDisabled: "Location History was disabled"
        case .saveFailed: "History could not be saved"
        case .locationTemporarilyUnavailable: "iOS temporarily could not determine a reliable location"
        case .unknownDiscontinuity: "Reliable updates were interrupted"
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
