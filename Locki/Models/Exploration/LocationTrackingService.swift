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
    private(set) var continuousBackgroundTrackingEnabled: Bool

    @ObservationIgnored var deltaHandler: ((CoverageDelta) -> Void)?
    @ObservationIgnored var pathAnchorHandler: ((PathAnchor) -> Void)?
    @ObservationIgnored var pathAnchorPurgeHandler: (() -> Void)?

    @ObservationIgnored private let locationManager: CLLocationManager
    @ObservationIgnored private let engine: ExplorationEngine
    @ObservationIgnored private var previousSample: ExplorationLocationSample?
    @ObservationIgnored private var standardUpdatesRunning = false
    @ObservationIgnored private var significantChangeMonitoringRunning = false
    @ObservationIgnored private var applicationIsActive = true

    private static let fullAccuracyPurposeKey = "ExplorationPrecision"
    private static let continuousBackgroundTrackingKey = "exploration.continuousBackgroundTracking"

    init(
        locationManager: CLLocationManager = CLLocationManager(),
        engine: ExplorationEngine = ExplorationEngine()
    ) {
        self.locationManager = locationManager
        self.engine = engine
        authorizationStatus = locationManager.authorizationStatus
        accuracyAuthorization = locationManager.accuracyAuthorization
        continuousBackgroundTrackingEnabled = UserDefaults.standard.bool(
            forKey: Self.continuousBackgroundTrackingKey
        )
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

    func requestForegroundLocationAccess() {
        switch authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            beginLocationUpdates()
        case .denied:
            state = .unavailable(.authorizationDenied)
        case .restricted:
            state = .unavailable(.authorizationRestricted)
        @unknown default:
            state = .failed
        }
    }

    func requestAlwaysLocationAccess() {
        switch authorizationStatus {
        case .authorizedWhenInUse:
            locationManager.requestAlwaysAuthorization()
        case .authorizedAlways:
            beginLocationUpdates()
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
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

    func setApplicationIsActive(_ isActive: Bool) {
        applicationIsActive = isActive
        updateLocationDelivery()
    }

    func setContinuousBackgroundTrackingEnabled(_ enabled: Bool) {
        continuousBackgroundTrackingEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.continuousBackgroundTrackingKey)

        if enabled, authorizationStatus != .authorizedAlways {
            requestAlwaysLocationAccess()
        }
        updateLocationDelivery()
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
                pathAnchorPurgeHandler?()
                state = .unavailable(.authorizationDenied)
            case .restricted:
                stopLocationUpdates()
                pathAnchorPurgeHandler?()
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
            stopStandardUpdates()
            state = .requiresPreciseLocation
            return
        }

        if !significantChangeMonitoringRunning {
            locationManager.startMonitoringSignificantLocationChanges()
            significantChangeMonitoringRunning = true
        }

        updateLocationDelivery()
        state = .active
    }

    private func updateLocationDelivery() {
        guard hasLocationAccess, accuracyAuthorization == .fullAccuracy else { return }

        let shouldRunStandardUpdates = applicationIsActive || continuousBackgroundTrackingEnabled
        if shouldRunStandardUpdates, !standardUpdatesRunning {
            locationManager.allowsBackgroundLocationUpdates = continuousBackgroundTrackingEnabled
            locationManager.showsBackgroundLocationIndicator = continuousBackgroundTrackingEnabled
            locationManager.startUpdatingLocation()
            standardUpdatesRunning = true
        } else if !shouldRunStandardUpdates, standardUpdatesRunning {
            stopStandardUpdates()
        } else if standardUpdatesRunning {
            locationManager.allowsBackgroundLocationUpdates = continuousBackgroundTrackingEnabled
            locationManager.showsBackgroundLocationIndicator = continuousBackgroundTrackingEnabled
        }
    }

    private func stopLocationUpdates() {
        stopStandardUpdates()
        if significantChangeMonitoringRunning {
            locationManager.stopMonitoringSignificantLocationChanges()
            significantChangeMonitoringRunning = false
        }
        locationManager.allowsBackgroundLocationUpdates = false
        locationManager.showsBackgroundLocationIndicator = false
        previousSample = nil
    }

    private func stopStandardUpdates() {
        if standardUpdatesRunning {
            locationManager.stopUpdatingLocation()
            standardUpdatesRunning = false
        }
        locationManager.allowsBackgroundLocationUpdates = false
        locationManager.showsBackgroundLocationIndicator = false
        previousSample = nil
    }

    private func consume(_ locations: [CLLocation]) {
        guard accuracyAuthorization == .fullAccuracy else {
            state = .requiresPreciseLocation
            return
        }

        let isSignificantChangeDelivery = !standardUpdatesRunning
        for location in locations.sorted(by: { $0.timestamp < $1.timestamp }) {
            let sample = ExplorationLocationSample(location: location, hasPreciseAccuracy: true)
            let delta = engine.process(sample: sample, previous: previousSample)

            if engine.acceptedSample(sample) {
                previousSample = sample
                state = .active
                if isSignificantChangeDelivery {
                    pathAnchorHandler?(PathAnchor(sample: sample))
                }
            }
            if !delta.isEmpty {
                deltaHandler?(delta)
            }
        }
    }
}
