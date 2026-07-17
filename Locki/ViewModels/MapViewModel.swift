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

    let locationTracking: LocationTrackingService

    @ObservationIgnored private var coverageStore: CoverageStore?
    @ObservationIgnored private var pendingDelta = CoverageDelta(unlockedAt: .distantPast)
    @ObservationIgnored private var flushTask: Task<Void, Never>?

    init(locationTracking: LocationTrackingService = LocationTrackingService()) {
        self.locationTracking = locationTracking
        locationTracking.deltaHandler = { [weak self] delta in
            self?.receive(delta)
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

    var explorationStatusMessage: String {
        if persistenceIssue { return "New coverage is visible now, but may not be saved." }
        return switch locationTracking.state {
        case .waitingForPermission:
            "Allow Always Location to begin street-level exploration."
        case .active:
            "\(exploredTileCount.formatted()) street cells cleared on this device."
        case .stationary:
            "Tracking is resting until you move again."
        case .requiresPreciseLocation:
            "Precise Location prevents clearing the wrong street."
        case .unavailable:
            "Locki could not read a reliable current location."
        case .failed:
            "Location updates stopped unexpectedly. Reopen Locki to try again."
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
        locationTracking.start()

        Task {
            do {
                coverageSnapshot = try await store.prepare()
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

    func setApplicationIsActive(_ isActive: Bool) {
        locationTracking.setApplicationIsActive(isActive)
    }

    func recenterMap() {
        guard canRecenterMap else { return }
        recenterRequest &+= 1
    }

    func flushCoverage() {
        Task { await flushPendingCoverage() }
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
