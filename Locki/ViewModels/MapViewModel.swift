//
//  MapViewModel.swift
//  Locki
//
//  Created by Max Oliinyk on 06.05.2026.
//

import CoreLocation
import MapKit
import Observation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class MapViewModel {
    var mapStyle: LockiMapStyle = .standard
    private(set) var coverageSnapshot: CoverageSnapshot = .empty
    private(set) var recenterRequest = 0
    private(set) var persistenceIssue = false
    private(set) var pendingPathAnchorCount = 0
    private(set) var matchedPathCount = 0

    let locationTracking: LocationTrackingService

    @ObservationIgnored private var coverageStore: CoverageStore?
    @ObservationIgnored private var pendingDelta = CoverageDelta(unlockedAt: .distantPast)
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var pathMatchingCoordinator: PathMatchingCoordinator?

    init(locationTracking: LocationTrackingService = LocationTrackingService()) {
        self.locationTracking = locationTracking
        locationTracking.deltaHandler = { [weak self] delta in
            self?.receive(delta)
        }
        locationTracking.pathAnchorHandler = { [weak self] anchor in
            self?.pathMatchingCoordinator?.enqueue(anchor)
        }
        locationTracking.pathAnchorPurgeHandler = { [weak self] in
            self?.pathMatchingCoordinator?.purge()
        }
    }

    var locationAuthorizationStatus: CLAuthorizationStatus {
        locationTracking.authorizationStatus
    }

    var showsUserLocation: Bool {
        locationTracking.hasLocationAccess
    }

    var showsLocationOnboarding: Bool {
        !locationTracking.hasLocationAccess
    }

    var canRecenterMap: Bool {
        locationTracking.hasLocationAccess
    }

    var exploredTileCount: Int {
        coverageSnapshot.totalExploredCellCount
    }

    var lastUnlockDate: Date? {
        coverageSnapshot.lastUnlockDate
    }

    var continuousBackgroundTrackingEnabled: Bool {
        locationTracking.continuousBackgroundTrackingEnabled
    }

    var trackingMode: TrackingMode { locationTracking.trackingMode }

    var locationPermissionTitle: String {
        switch locationAuthorizationStatus {
        case .authorizedAlways:
            "Always allowed"
        case .authorizedWhenInUse:
            "While using Locki"
        case .denied:
            "Location denied"
        case .restricted:
            "Location restricted"
        case .notDetermined:
            "Location not requested"
        @unknown default:
            "Location unavailable"
        }
    }

    var locationPermissionButtonTitle: String {
        switch locationAuthorizationStatus {
        case .denied, .restricted:
            "Open Settings"
        default:
            "Enable Exploration"
        }
    }

    var locationPermissionDescription: String {
        switch locationAuthorizationStatus {
        case .authorizedAlways:
            "Locki explores precisely while open and checks for meaningful movement in the background. Continuous background precision is optional."
        case .authorizedWhenInUse where locationTracking.accuracyAuthorization != .fullAccuracy:
            "Turn on Precise Location so Locki clears the correct street."
        case .authorizedWhenInUse:
            "Locki clears your private map while open. Enable Always Location for movement-driven background exploration."
        case .denied:
            "Allow location in Settings to clear the textured fog from places you visit."
        case .restricted:
            "Location access is restricted on this device."
        case .notDetermined:
            "Enable exploration to clear street-level fog as you walk and travel. Coverage stays on this device."
        @unknown default:
            "Locki cannot determine location permission right now."
        }
    }

    var locationPermissionSystemImage: String {
        switch locationAuthorizationStatus {
        case .authorizedAlways:
            "location.fill"
        case .authorizedWhenInUse:
            "location"
        case .denied, .restricted:
            "location.slash"
        case .notDetermined:
            "location.circle"
        @unknown default:
            "questionmark.circle"
        }
    }

    var explorationStatusTitle: String {
        if persistenceIssue { return "Saving unavailable" }
        return switch locationTracking.state {
        case .waitingForPermission:
            "Waiting for location"
        case .active:
            "Exploring"
        case .stationary:
            "Exploration ready"
        case .requiresPreciseLocation:
            "Precise Location needed"
        case .unavailable:
            "Location unavailable"
        case .failed:
            "Exploration unavailable"
        }
    }

    var explorationStatusSystemImage: String {
        if persistenceIssue { return "externaldrive.badge.exclamationmark" }
        return switch locationTracking.state {
        case .waitingForPermission:
            "location.circle"
        case .active:
            "map.fill"
        case .stationary:
            "figure.stand"
        case .requiresPreciseLocation:
            "scope"
        case .unavailable, .failed:
            "location.slash"
        }
    }

    func configurePersistence(modelContainer: ModelContainer) {
        guard coverageStore == nil else { return }
        let store = CoverageStore(modelContainer: modelContainer)
        coverageStore = store
        let coordinator = PathMatchingCoordinator(
            store: store,
            coverageHandler: { [weak self] delta, result in
                self?.receiveMatched(delta, result: result)
            },
            statusHandler: { [weak self] pendingCount, matchedCount in
                self?.pendingPathAnchorCount = pendingCount
                self?.matchedPathCount = matchedCount
            },
            persistenceIssueHandler: { [weak self] hasIssue in
                self?.persistenceIssue = hasIssue
            }
        )
        pathMatchingCoordinator = coordinator
        locationTracking.start()

        Task {
            do {
                coverageSnapshot = try await store.prepare()
                let summary = try await store.summary()
                let anchors = try await store.pendingPathAnchors()
                matchedPathCount = summary.matchedPathCount
                pendingPathAnchorCount = anchors.count
                coordinator.resume()
            } catch {
                persistenceIssue = true
            }
        }
    }

    func requestLocationAccess() {
        switch locationAuthorizationStatus {
        case .denied, .restricted:
            openAppSettings()
        default:
            locationTracking.requestForegroundLocationAccess()
        }
    }

    func requestBackgroundLocationAccess() {
        locationTracking.requestAlwaysLocationAccess()
    }

    func requestPreciseLocation() {
        locationTracking.requestPreciseLocation()
    }

    func setContinuousBackgroundTrackingEnabled(_ enabled: Bool) {
        locationTracking.setContinuousBackgroundTrackingEnabled(enabled)
    }

    func setTrackingMode(_ mode: TrackingMode) {
        locationTracking.setTrackingMode(mode)
    }

    func setApplicationIsActive(_ isActive: Bool) {
        locationTracking.setApplicationIsActive(isActive)
        if isActive { pathMatchingCoordinator?.resume() }
    }

    func recenterMap() {
        guard canRecenterMap else { return }
        recenterRequest &+= 1
    }

    func flushCoverage() {
        Task { await flushPendingCoverage() }
    }

    func processPendingPathMatches(deadline: Date? = nil) async -> PathProcessingResult {
        guard let pathMatchingCoordinator else { return .idle }
        return await pathMatchingCoordinator.processPending(deadline: deadline)
    }

    func deleteExplorationData() async -> Bool {
        guard let coverageStore else { return false }
        flushTask?.cancel()
        flushTask = nil
        pendingDelta = CoverageDelta(unlockedAt: .distantPast)
        pathMatchingCoordinator?.purge()
        do {
            coverageSnapshot = try await coverageStore.reset()
            pendingPathAnchorCount = 0
            matchedPathCount = 0
            persistenceIssue = false
            return true
        } catch {
            persistenceIssue = true
            return false
        }
    }

    private func receive(_ delta: CoverageDelta) {
        coverageSnapshot.apply(delta)
        pendingDelta.formUnion(delta)

        if pendingDelta.chunks.count >= 32 {
            flushTask?.cancel()
            flushTask = nil
            Task { await flushPendingCoverage() }
        } else if flushTask == nil {
            flushTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await self?.flushPendingCoverage()
            }
        }
    }

    private func receiveMatched(_ delta: CoverageDelta, result: PathMatchCommitResult) {
        coverageSnapshot.apply(delta)
        pendingPathAnchorCount = result.pendingAnchorCount
        matchedPathCount = result.matchedPathCount
        persistenceIssue = false
    }

    private func flushPendingCoverage() async {
        flushTask?.cancel()
        flushTask = nil
        guard let coverageStore, !pendingDelta.isEmpty else { return }

        let delta = pendingDelta
        pendingDelta = CoverageDelta(unlockedAt: .distantPast)
        do {
            coverageSnapshot = try await coverageStore.merge(delta)
            persistenceIssue = false
        } catch {
            pendingDelta.formUnion(delta)
            persistenceIssue = true
        }
    }

    private func openAppSettings() {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(settingsURL)
    }

}
