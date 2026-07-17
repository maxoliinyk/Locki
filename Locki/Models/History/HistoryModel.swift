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

    @ObservationIgnored private var store: HistoryStore?
    @ObservationIgnored private weak var locationTracking: LocationTrackingService?
    @ObservationIgnored private var eventContinuation: AsyncStream<HistoryEvent>.Continuation?
    @ObservationIgnored private var ingestionTask: Task<Void, Never>?

    private static let historyEnabledKey = "history.enabled"

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.historyEnabledKey)
    }

    func configure(modelContainer: ModelContainer, locationTracking: LocationTrackingService) {
        guard store == nil else { return }
        let store = HistoryStore(modelContainer: modelContainer)
        self.store = store
        self.locationTracking = locationTracking

        let stream = AsyncStream<HistoryEvent> { [weak self] continuation in
            self?.eventContinuation = continuation
        }
        locationTracking.historyEventHandler = { [weak self] event in
            self?.eventContinuation?.yield(event)
        }
        ingestionTask = Task { [weak self] in
            for await event in stream {
                guard let self else { break }
                do {
                    overview = try await store.ingest(event)
                    persistenceIssue = false
                } catch {
                    persistenceIssue = true
                }
            }
        }

        Task {
            do {
                overview = try await store.prepare()
                overview = try await store.setEnabled(isEnabled)
                if isEnabled {
                    locationTracking.setHistoryTrackingEnabled(true)
                }
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
            locationTracking.setHistoryTrackingEnabled(false)
        }
        Task {
            do {
                overview = try await store.setEnabled(enabled)
                if enabled {
                    locationTracking.setHistoryTrackingEnabled(true)
                }
                persistenceIssue = false
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

    func deleteTrip(id: UUID) {
        guard let store else { return }
        Task {
            do { overview = try await store.deleteTrip(id: id) }
            catch { persistenceIssue = true }
        }
    }

    func deleteVisit(id: UUID) {
        guard let store else { return }
        Task {
            do { overview = try await store.deleteVisit(id: id) }
            catch { persistenceIssue = true }
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
