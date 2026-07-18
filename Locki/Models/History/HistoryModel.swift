//
//  HistoryModel.swift
//  Locki
//
//  Created by Max Oliinyk on 17.07.2026.
//

import Foundation
import Observation
import SwiftData

nonisolated enum HistoryExportFormat: String, CaseIterable, Identifiable, Sendable {
    case json
    case gpx

    var id: String { rawValue }
    var displayName: String { rawValue.uppercased() }
}

@MainActor
@Observable
final class HistoryModel {
    private(set) var isEnabled: Bool
    private(set) var overview = HistoryOverview()
    private(set) var persistenceIssue = false
    private(set) var isExporting = false
    private(set) var exportURL: URL?
    private(set) var gapRouteSuggestions: [UUID: [GapRouteSuggestion]] = [:]
    private(set) var gapRouteLoadingIDs: Set<UUID> = []
    private(set) var gapRouteFailureIDs: Set<UUID> = []

    @ObservationIgnored private var store: HistoryStore?
    @ObservationIgnored private weak var locationTracking: LocationTrackingService?
    @ObservationIgnored private weak var oneShotLocationProvider: (any OneShotLocationProviding)?
    @ObservationIgnored private var eventContinuation: AsyncStream<HistoryEvent>.Continuation?
    @ObservationIgnored private var ingestionTask: Task<Void, Never>?
    @ObservationIgnored private var dwellCheckTask: Task<Void, Never>?
    @ObservationIgnored private var monitorRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var opportunisticFixTask: Task<Void, Never>?
    @ObservationIgnored private var motionService: (any MotionActivityProviding)?
    @ObservationIgnored private var placeMonitor: (any PlaceMonitoring)?
    @ObservationIgnored private var backgroundRefresh: (any BackgroundRefreshScheduling)?
    @ObservationIgnored private var trackingHealth: TrackingHealthModel?
    @ObservationIgnored private var isBackupImportPaused = false
    @ObservationIgnored private let gapRouteProvider: any GapRouteProviding
    @ObservationIgnored private var gapRouteTasks: [UUID: Task<[GapRouteCandidate], Error>] = [:]
    @ObservationIgnored private var gapRouteRequestIDs: [UUID: UUID] = [:]

    private static let historyEnabledKey = "history.enabled"

    init(gapRouteProvider: any GapRouteProviding = MapKitGapRouteProvider()) {
        self.gapRouteProvider = gapRouteProvider
        isEnabled = UserDefaults.standard.bool(forKey: Self.historyEnabledKey)
    }

    func configure(
        modelContainer: ModelContainer,
        locationTracking: LocationTrackingService,
        motionService: any MotionActivityProviding,
        placeMonitor: any PlaceMonitoring,
        backgroundRefresh: any BackgroundRefreshScheduling,
        trackingHealth: TrackingHealthModel
    ) {
        guard store == nil else { return }
        let store = HistoryStore(modelContainer: modelContainer)
        self.store = store
        self.locationTracking = locationTracking
        oneShotLocationProvider = locationTracking
        self.motionService = motionService
        self.placeMonitor = placeMonitor
        self.backgroundRefresh = backgroundRefresh
        self.trackingHealth = trackingHealth

        let stream = AsyncStream<HistoryEvent> { [weak self] continuation in
            self?.eventContinuation = continuation
        }
        locationTracking.historyEventHandler = { [weak self] event in
            self?.trackingHealth?.recordPassiveEvent(event.healthTitle)
            self?.eventContinuation?.yield(event)
            if case .visit = event { self?.requestOpportunisticFix() }
        }
        motionService.eventHandler = { [weak self] sample in
            self?.trackingHealth?.recordPassiveEvent("Motion")
            self?.locationTracking?.updatePathMotion(sample)
            self?.eventContinuation?.yield(.motion(sample))
        }
        placeMonitor.eventHandler = { [weak self] event in
            self?.trackingHealth?.recordPassiveEvent("Place boundary", at: event.date)
            self?.eventContinuation?.yield(.region(event))
            self?.requestOpportunisticFix()
        }
        ingestionTask = Task { [weak self] in
            for await event in stream {
                guard let self else { break }
                guard !isBackupImportPaused else { continue }
                do {
                    overview = try await store.ingest(event)
                    persistenceIssue = false
                    scheduleMonitorRefresh()
                } catch {
                    persistenceIssue = true
                }
            }
        }

        if isEnabled {
            locationTracking.setHistoryTrackingEnabled(true)
            motionService.start()
            backgroundRefresh.schedule()
            startDwellChecks()
        }

        Task {
            do {
                overview = try await store.prepare()
                overview = try await store.setEnabled(isEnabled)
                scheduleMonitorRefresh()
            } catch {
                persistenceIssue = true
            }
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard let store, let locationTracking else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.historyEnabledKey)
        if !enabled {
            stopDwellChecks()
            opportunisticFixTask?.cancel()
            opportunisticFixTask = nil
            locationTracking.setHistoryTrackingEnabled(false)
            motionService?.stop()
            backgroundRefresh?.cancel()
            Task { await placeMonitor?.removeAll() }
        }
        Task {
            do {
                overview = try await store.setEnabled(enabled)
                if enabled {
                    locationTracking.setHistoryTrackingEnabled(true)
                    motionService?.start()
                    backgroundRefresh?.schedule()
                    startDwellChecks()
                }
                persistenceIssue = false
                scheduleMonitorRefresh()
            } catch {
                persistenceIssue = true
            }
        }
    }

    func refresh() async {
        guard let store else { return }
        do {
            overview = try await store.overview()
            persistenceIssue = false
        } catch {
            persistenceIssue = true
        }
    }

    func gapSnapshot(id: UUID) async -> HistoryGapSnapshot? {
        do {
            let snapshot = try await store?.gapSnapshot(id: id)
            persistenceIssue = false
            return snapshot
        } catch {
            persistenceIssue = true
            return nil
        }
    }

    @discardableResult
    func findGapRoutes(id: UUID, mode: HistoryGapTravelMode) async -> Bool {
        guard let snapshot = await gapSnapshot(id: id),
              snapshot.assessment.canRequestRoutes,
              let start = snapshot.assessment.start,
              let end = snapshot.assessment.end,
              let distance = snapshot.assessment.directDistanceMeters,
              let duration = snapshot.duration else { return false }
        cancelGapRouteRequest(id: id)
        gapRouteLoadingIDs.insert(id)
        gapRouteFailureIDs.remove(id)
        gapRouteSuggestions[id] = []
        let requestID = UUID()
        gapRouteRequestIDs[id] = requestID
        let task = Task {
            try await gapRouteProvider.routes(
                from: start.coordinate,
                to: end.coordinate,
                departureDate: snapshot.startedAt,
                mode: mode
            )
        }
        gapRouteTasks[id] = task
        defer {
            if gapRouteRequestIDs[id] == requestID {
                gapRouteTasks[id] = nil
                gapRouteRequestIDs[id] = nil
                gapRouteLoadingIDs.remove(id)
            }
        }
        do {
            let candidates = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            let suggestions = HistoryGapAssessmentEngine().rankedSuggestions(
                candidates,
                gapDuration: duration,
                directDistanceMeters: distance
            )
            guard gapRouteRequestIDs[id] == requestID else { return false }
            gapRouteSuggestions[id] = suggestions
            if suggestions.isEmpty { gapRouteFailureIDs.insert(id) }
            return !suggestions.isEmpty
        } catch is CancellationError {
            return false
        } catch {
            if gapRouteRequestIDs[id] == requestID { gapRouteFailureIDs.insert(id) }
            return false
        }
    }

    func cancelGapRouteRequest(id: UUID) {
        gapRouteTasks[id]?.cancel()
        gapRouteTasks[id] = nil
        gapRouteRequestIDs[id] = nil
        gapRouteLoadingIDs.remove(id)
    }

    func confirmGapRoute(id: UUID, suggestion: GapRouteSuggestion) async -> Bool {
        guard let store else { return false }
        do {
            try await store.resolveGapRoute(id: id, suggestion: suggestion)
            gapRouteSuggestions[id] = []
            persistenceIssue = false
            return true
        } catch {
            persistenceIssue = true
            return false
        }
    }

    func markGapAsNoMovement(id: UUID) async -> Bool {
        await mutateGap { try await $0.resolveGapNoMovement(id: id) }
    }

    func dismissGap(id: UUID) async -> Bool {
        await mutateGap { try await $0.dismissGap(id: id) }
    }

    func restoreGap(id: UUID) async -> Bool {
        await mutateGap { try await $0.restoreGap(id: id) }
    }

    func applyGapBatch(
        ids: Set<UUID>,
        action: HistoryGapBatchAction
    ) async -> HistoryGapBatchResult? {
        guard let store else { return nil }
        do {
            let result = try await store.applyGapBatch(ids: ids, action: action)
            for id in result.appliedIDs {
                cancelGapRouteRequest(id: id)
                gapRouteSuggestions[id] = []
                gapRouteFailureIDs.remove(id)
            }
            persistenceIssue = false
            return result
        } catch {
            persistenceIssue = true
            return nil
        }
    }

    private func mutateGap(
        _ operation: (HistoryStore) async throws -> Void
    ) async -> Bool {
        guard let store else { return false }
        do {
            try await operation(store)
            overview = try await store.overview()
            persistenceIssue = false
            return true
        } catch {
            persistenceIssue = true
            return false
        }
    }

    func flushForBackup() async throws {
        try await store?.flush()
    }

    func pauseForBackupImport() async {
        isBackupImportPaused = true
        stopDwellChecks()
        monitorRefreshTask?.cancel()
        monitorRefreshTask = nil
        opportunisticFixTask?.cancel()
        opportunisticFixTask = nil
        locationTracking?.setHistoryTrackingEnabled(false)
        motionService?.stop()
        backgroundRefresh?.cancel()
        await placeMonitor?.removeAll()
        try? await store?.flush()
    }

    func resumeAfterBackupImport() async {
        isBackupImportPaused = false
        await refresh()
        guard isEnabled else { return }
        locationTracking?.setHistoryTrackingEnabled(true)
        motionService?.start()
        backgroundRefresh?.schedule()
        startDwellChecks()
        scheduleMonitorRefresh()
    }

    func checkCurrentStay() {
        guard isEnabled else { return }
        eventContinuation?.yield(.dwellCheck(.now))
    }

    func requestMotionAuthorization() {
        motionService?.requestAuthorization()
    }

    func reconcile(reason: HistoryReconciliationReason) async {
        guard isEnabled, let store else { return }
        do {
            let now = Date.now
            if let motionService {
                let start = max(overview.latestEventAt ?? now - 24 * 60 * 60, now - 24 * 60 * 60)
                for activity in await motionService.historicalActivity(from: start, to: now) {
                    overview = try await store.ingest(.motion(activity), now: now)
                }
            }
            let candidates = try await store.monitoredPlaceCandidates()
            await placeMonitor?.update(candidates)
            await placeMonitor?.reconcile()
            if reason != .backgroundRefresh {
                _ = await oneShotLocationProvider?.requestOneShotLocation(timeout: .seconds(12))
            }
            overview = try await store.ingest(.reconcile(.now, reason))
            persistenceIssue = false
            scheduleMonitorRefresh()
        } catch {
            persistenceIssue = true
        }
    }

    func performBackgroundRefresh() async -> Bool {
        guard isEnabled,
              let store,
              oneShotLocationProvider != nil,
              let motionService,
              let placeMonitor else { return false }
        let now = Date.now
        let queryStart = max(overview.latestEventAt ?? now - 24 * 60 * 60, now - 24 * 60 * 60)
        do {
            for activity in await motionService.historicalActivity(from: queryStart, to: now) {
                overview = try await store.ingest(.motion(activity), now: now)
            }
            let candidates = try await store.monitoredPlaceCandidates()
            await placeMonitor.update(candidates)
            await placeMonitor.reconcile()
            _ = await oneShotLocationProvider?.requestOneShotLocation(timeout: .seconds(12))
            overview = try await store.ingest(.reconcile(.now, .backgroundRefresh))
            let refreshedCandidates = try await store.monitoredPlaceCandidates()
            await placeMonitor.update(refreshedCandidates)
            trackingHealth?.setMonitoredPlaceCount(placeMonitor.monitoredCount)
            trackingHealth?.recordRefresh(success: true)
            persistenceIssue = false
            return true
        } catch {
            trackingHealth?.recordRefresh(success: false)
            persistenceIssue = true
            return false
        }
    }

    private func scheduleMonitorRefresh() {
        guard isEnabled, let store, let placeMonitor else { return }
        monitorRefreshTask?.cancel()
        monitorRefreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return }
            guard let self else { return }
            do {
                let candidates = try await store.monitoredPlaceCandidates()
                await placeMonitor.update(candidates)
                trackingHealth?.setMonitoredPlaceCount(placeMonitor.monitoredCount)
            } catch {
                persistenceIssue = true
            }
        }
    }

    private func startDwellChecks() {
        dwellCheckTask?.cancel()
        dwellCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.checkCurrentStay()
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    return
                }
            }
        }
    }

    private func requestOpportunisticFix() {
        guard isEnabled, opportunisticFixTask == nil, let oneShotLocationProvider else { return }
        opportunisticFixTask = Task { [weak self] in
            _ = await oneShotLocationProvider.requestOneShotLocation(timeout: .seconds(8))
            self?.opportunisticFixTask = nil
        }
    }

    private func stopDwellChecks() {
        dwellCheckTask?.cancel()
        dwellCheckTask = nil
    }

    func deleteTrip(id: UUID) async -> Bool {
        guard let store else { return false }
        do {
            overview = try await store.deleteTrip(id: id)
            persistenceIssue = false
            return true
        } catch {
            persistenceIssue = true
            return false
        }
    }

    func deleteVisit(id: UUID) async -> Bool {
        guard let store else { return false }
        do {
            overview = try await store.deleteVisit(id: id)
            persistenceIssue = false
            return true
        } catch {
            persistenceIssue = true
            return false
        }
    }

    func deleteAllHistory() async -> Bool {
        guard let store else { return false }
        do {
            overview = try await store.deleteAll()
            if isEnabled { overview = try await store.setEnabled(true) }
            persistenceIssue = false
            return true
        } catch {
            persistenceIssue = true
            return false
        }
    }

    func deleteHistory(from start: Date, to end: Date) async -> Bool {
        guard let store, end >= start else { return false }
        do {
            overview = try await store.deleteHistory(
                from: Calendar.current.startOfDay(for: start),
                to: Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: end))
            )
            persistenceIssue = false
            return true
        } catch {
            persistenceIssue = true
            return false
        }
    }

    func setFavorite(placeID: UUID, isFavorite: Bool) {
        guard let store else { return }
        Task {
            do { try await store.setFavorite(placeID: placeID, isFavorite: isFavorite) }
            catch { persistenceIssue = true }
        }
    }

    func setFavorite(routeID: UUID, isFavorite: Bool) {
        guard let store else { return }
        Task {
            do { try await store.setFavorite(routeID: routeID, isFavorite: isFavorite) }
            catch { persistenceIssue = true }
        }
    }

    func updateRoute(id: UUID, name: String?, isExcluded: Bool) async -> Bool {
        guard let store else { return false }
        do {
            try await store.updateRoute(id: id, name: name, isExcluded: isExcluded)
            return true
        } catch {
            persistenceIssue = true
            return false
        }
    }

    func mergeRoutes(sourceID: UUID, destinationID: UUID) async -> Bool {
        guard let store else { return false }
        do {
            try await store.mergeRoutes(sourceID: sourceID, destinationID: destinationID)
            return true
        } catch {
            persistenceIssue = true
            return false
        }
    }

    func splitTripFromRoute(tripID: UUID) async -> Bool {
        guard let store else { return false }
        do {
            try await store.splitTripFromRoute(tripID: tripID)
            return true
        } catch {
            persistenceIssue = true
            return false
        }
    }

    func updatePlace(id: UUID, name: String, category: String?, source: String = "user") async -> Bool {
        guard let store else { return false }
        do {
            try await store.updatePlace(id: id, name: name, category: category, source: source)
            return true
        } catch {
            persistenceIssue = true
            return false
        }
    }

    func mergePlaces(sourceID: UUID, destinationID: UUID) async -> Bool {
        guard let store else { return false }
        do {
            try await store.mergePlaces(sourceID: sourceID, destinationID: destinationID)
            overview = try await store.overview()
            return true
        } catch {
            persistenceIssue = true
            return false
        }
    }

    func splitVisit(id: UUID) async -> Bool {
        guard let store else { return false }
        do {
            try await store.splitVisit(id: id)
            overview = try await store.overview()
            return true
        } catch {
            persistenceIssue = true
            return false
        }
    }

    func setPlaceExcluded(id: UUID, isExcluded: Bool) {
        guard let store else { return }
        Task {
            do { try await store.setPlaceExcluded(id: id, isExcluded: isExcluded) }
            catch { persistenceIssue = true }
        }
    }

    func dismissLabelSuggestion(placeID: UUID, suggestion: PlaceLabelSuggestion) {
        guard let store else { return }
        Task {
            do { try await store.dismissLabelSuggestion(id: placeID, suggestion: suggestion) }
            catch { persistenceIssue = true }
        }
    }

    func prepareExport(_ format: HistoryExportFormat) async {
        guard let store else { return }
        isExporting = true
        defer { isExporting = false }
        do {
            let data = switch format {
            case .json: try await store.exportJSON()
            case .gpx: try await store.exportGPX()
            }
            removeExportFile()
            let url = FileManager.default.temporaryDirectory
                .appending(path: "Locki-History-\(Int(Date.now.timeIntervalSince1970)).\(format.rawValue)")
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            exportURL = url
        } catch {
            persistenceIssue = true
        }
    }

    func removeExportFile() {
        guard let exportURL else { return }
        try? FileManager.default.removeItem(at: exportURL)
        self.exportURL = nil
    }
}

private extension HistoryEvent {
    var healthTitle: String {
        switch self {
        case .sample: "Location"
        case .visit: "System visit"
        case .region: "Place boundary"
        case .motion: "Motion"
        case .dwellCheck: "Stay check"
        case .reconcile(_, let reason): reason == .backgroundRefresh ? "Background refresh" : "Reconciliation"
        case .gap: "Tracking gap"
        }
    }
}
