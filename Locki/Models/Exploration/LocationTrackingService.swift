//
//  LocationTrackingService.swift
//  Locki
//
//  Created by Max Oliinyk on 17.07.2026.
//

import CoreLocation
import Foundation
import Observation

nonisolated enum LocationTrackingDiagnostic: Hashable, Sendable {
    case authorizationDenied
    case authorizationRestricted
    case locationUnavailable
}

nonisolated enum LocationTrackingState: Hashable, Sendable {
    case waitingForPermission
    case active
    case stationary
    case requiresPreciseLocation
    case unavailable(LocationTrackingDiagnostic)
    case failed
}

@MainActor
@Observable
final class LocationTrackingService: NSObject, CLLocationManagerDelegate {
    private(set) var state: LocationTrackingState
    private(set) var authorizationStatus: CLAuthorizationStatus
    private(set) var accuracyAuthorization: CLAccuracyAuthorization

    @ObservationIgnored var deltaHandler: ((CoverageDelta) -> Void)?

    @ObservationIgnored private let locationManager: CLLocationManager
    @ObservationIgnored private let engine: ExplorationEngine
    @ObservationIgnored private var previousSample: ExplorationLocationSample?
    @ObservationIgnored private var isRunning = false

    private static let fullAccuracyPurposeKey = "ExplorationPrecision"

    init(
        locationManager: CLLocationManager = CLLocationManager(),
        engine: ExplorationEngine = ExplorationEngine()
    ) {
        self.locationManager = locationManager
        self.engine = engine
        authorizationStatus = locationManager.authorizationStatus
        accuracyAuthorization = locationManager.accuracyAuthorization
        state = locationManager.authorizationStatus == .notDetermined
            ? .waitingForPermission
            : .active
        super.init()

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 5
        locationManager.activityType = .otherNavigation
        locationManager.pausesLocationUpdatesAutomatically = true
    }

    var hasLocationAccess: Bool {
        authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse
    }

    var hasAlwaysLocationAccess: Bool {
        authorizationStatus == .authorizedAlways
    }

    func start() {
        guard hasLocationAccess else {
            state = authorizationStatus == .restricted
                ? .unavailable(.authorizationRestricted)
                : authorizationStatus == .denied
                    ? .unavailable(.authorizationDenied)
                    : .waitingForPermission
            return
        }

        beginLocationUpdates()
    }

    func requestAlwaysLocationAccess() {
        switch authorizationStatus {
        case .notDetermined, .authorizedWhenInUse:
            locationManager.requestAlwaysAuthorization()
        case .authorizedAlways:
            beginLocationUpdates()
        case .denied:
            state = .unavailable(.authorizationDenied)
        case .restricted:
            state = .unavailable(.authorizationRestricted)
        @unknown default:
            state = .failed
        }
    }

    func requestPreciseLocation() {
        guard hasLocationAccess else { return }
        locationManager.requestTemporaryFullAccuracyAuthorization(
            withPurposeKey: Self.fullAccuracyPurposeKey
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.accuracyAuthorization = self.locationManager.accuracyAuthorization
                self.beginLocationUpdates()
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let authorization = manager.authorizationStatus
        let accuracy = manager.accuracyAuthorization

        Task { @MainActor in
            authorizationStatus = authorization
            accuracyAuthorization = accuracy

            switch authorization {
            case .authorizedAlways, .authorizedWhenInUse:
                beginLocationUpdates()
            case .notDetermined:
                state = .waitingForPermission
            case .denied:
                stopLocationUpdates()
                state = .unavailable(.authorizationDenied)
            case .restricted:
                stopLocationUpdates()
                state = .unavailable(.authorizationRestricted)
            @unknown default:
                stopLocationUpdates()
                state = .failed
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            consume(locations)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        let locationError = error as? CLError
        Task { @MainActor in
            if locationError?.code == .locationUnknown {
                state = .unavailable(.locationUnavailable)
            } else if locationError?.code == .denied {
                state = .unavailable(.authorizationDenied)
            } else {
                state = .failed
            }
        }
    }

    nonisolated func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        Task { @MainActor in state = .stationary }
    }

    nonisolated func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        Task { @MainActor in state = .active }
    }

    private func beginLocationUpdates() {
        guard hasLocationAccess else { return }

        accuracyAuthorization = locationManager.accuracyAuthorization
        guard accuracyAuthorization == .fullAccuracy else {
            state = .requiresPreciseLocation
            return
        }

        if !isRunning {
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.showsBackgroundLocationIndicator = true
            locationManager.startMonitoringSignificantLocationChanges()
            locationManager.startUpdatingLocation()
            isRunning = true
        }
        state = .active
    }

    private func stopLocationUpdates() {
        guard isRunning else { return }
        locationManager.stopUpdatingLocation()
        locationManager.stopMonitoringSignificantLocationChanges()
        previousSample = nil
        isRunning = false
    }

    private func consume(_ locations: [CLLocation]) {
        guard accuracyAuthorization == .fullAccuracy else {
            state = .requiresPreciseLocation
            return
        }

        for location in locations.sorted(by: { $0.timestamp < $1.timestamp }) {
            let sample = ExplorationLocationSample(location: location, hasPreciseAccuracy: true)
            let delta = engine.process(sample: sample, previous: previousSample)

            if engine.acceptedSample(sample) {
                previousSample = sample
                state = .active
            }
            if !delta.isEmpty {
                deltaHandler?(delta)
            }
        }
    }
}
