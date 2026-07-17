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
    private(set) var historyTrackingEnabled: Bool

    @ObservationIgnored var deltaHandler: ((CoverageDelta) -> Void)?
    @ObservationIgnored var pathAnchorHandler: ((PathAnchor) -> Void)?
    @ObservationIgnored var pathAnchorPurgeHandler: (() -> Void)?
    @ObservationIgnored var historyEventHandler: ((HistoryEvent) -> Void)?

    @ObservationIgnored private let locationManager: CLLocationManager
    @ObservationIgnored private let engine: ExplorationEngine
    @ObservationIgnored private var previousSample: ExplorationLocationSample?
    @ObservationIgnored private var standardUpdatesRunning = false
    @ObservationIgnored private var significantChangeMonitoringRunning = false
    @ObservationIgnored private var visitMonitoringRunning = false
    @ObservationIgnored private var applicationIsActive = true
    @ObservationIgnored private var historyGapStartedAt: Date?
    @ObservationIgnored private var historyGapReason: HistoryGapReason?
    @ObservationIgnored private var historyServiceSession: CLServiceSession?

    private static let fullAccuracyPurposeKey = "ExplorationPrecision"
    private static let continuousBackgroundTrackingKey = "exploration.continuousBackgroundTracking"
    private static let historyTrackingKey = "history.enabled"
    private static let historyBackgroundDefaultAppliedKey = "history.backgroundDefaultApplied"

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
        historyTrackingEnabled = UserDefaults.standard.bool(forKey: Self.historyTrackingKey)
        state = locationManager.authorizationStatus == .notDetermined
            ? .waitingForPermission
            : .active
        super.init()

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 10
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

    func setHistoryTrackingEnabled(_ enabled: Bool) {
        historyTrackingEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.historyTrackingKey)
        if enabled {
            historyServiceSession = CLServiceSession(
                authorization: .always,
                fullAccuracyPurposeKey: Self.fullAccuracyPurposeKey
            )
            if !UserDefaults.standard.bool(forKey: Self.historyBackgroundDefaultAppliedKey) {
                UserDefaults.standard.set(true, forKey: Self.historyBackgroundDefaultAppliedKey)
                setContinuousBackgroundTrackingEnabled(true)
            }
            startVisitMonitoring()
        } else {
            historyServiceSession?.invalidate()
            historyServiceSession = nil
            stopVisitMonitoring()
            beginHistoryGap(reason: .disabled)
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
                endHistoryGapIfNeeded()
                beginLocationUpdates()
            case .notDetermined:
                state = .waitingForPermission
            case .denied:
                beginHistoryGap(reason: .authorization)
                stopLocationUpdates()
                pathAnchorPurgeHandler?()
                state = .unavailable(.authorizationDenied)
            case .restricted:
                beginHistoryGap(reason: .authorization)
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
                beginHistoryGap(reason: .unavailable)
                state = .unavailable(.locationUnavailable)
            } else if locationError?.code == .denied {
                beginHistoryGap(reason: .authorization)
                state = .unavailable(.authorizationDenied)
            } else {
                beginHistoryGap(reason: .unavailable)
                state = .failed
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        let coordinate = GeoCoordinate(visit.coordinate)
        let accuracy = visit.horizontalAccuracy
        let arrival = visit.arrivalDate
        let departure = visit.departureDate == .distantFuture ? nil : visit.departureDate
        Task { @MainActor in
            guard historyTrackingEnabled else { return }
            historyEventHandler?(
                .visit(
                    SystemVisitSample(
                        coordinate: coordinate,
                        horizontalAccuracyMeters: accuracy,
                        arrivalDate: arrival,
                        departureDate: departure,
                        timeZoneIdentifier: TimeZone.current.identifier
                    )
                )
            )
        }
    }

    nonisolated func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        Task { @MainActor in
            if historyTrackingEnabled {
                historyEventHandler?(.dwellCheck(.now))
            }
            state = .stationary
        }
    }

    nonisolated func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        Task { @MainActor in state = .active }
    }

    private func beginLocationUpdates() {
        guard hasLocationAccess else { return }

        accuracyAuthorization = locationManager.accuracyAuthorization
        guard accuracyAuthorization == .fullAccuracy else {
            beginHistoryGap(reason: .reducedAccuracy)
            stopStandardUpdates()
            state = .requiresPreciseLocation
            return
        }
        endHistoryGapIfNeeded()

        if !significantChangeMonitoringRunning {
            locationManager.startMonitoringSignificantLocationChanges()
            significantChangeMonitoringRunning = true
        }
        if historyTrackingEnabled { startVisitMonitoring() }

        updateLocationDelivery()
        state = .active
    }

    private func updateLocationDelivery() {
        guard hasLocationAccess, accuracyAuthorization == .fullAccuracy else { return }

        locationManager.distanceFilter = ProcessInfo.processInfo.isLowPowerModeEnabled ? 25 : 10

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
        stopVisitMonitoring()
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
                endHistoryGapIfNeeded()
                previousSample = sample
                state = .active
                if historyTrackingEnabled {
                    historyEventHandler?(
                        .sample(
                            HistoryLocationSample(
                                location: location,
                                hasPreciseAccuracy: accuracyAuthorization == .fullAccuracy
                            )
                        )
                    )
                }
                if isSignificantChangeDelivery {
                    pathAnchorHandler?(PathAnchor(sample: sample))
                }
            }
            if !delta.isEmpty {
                deltaHandler?(delta)
            }
        }
    }

    private func startVisitMonitoring() {
        guard historyTrackingEnabled, hasLocationAccess, !visitMonitoringRunning else { return }
        locationManager.startMonitoringVisits()
        visitMonitoringRunning = true
    }

    private func stopVisitMonitoring() {
        guard visitMonitoringRunning else { return }
        locationManager.stopMonitoringVisits()
        visitMonitoringRunning = false
    }

    private func beginHistoryGap(reason: HistoryGapReason) {
        guard historyTrackingEnabled, historyGapStartedAt == nil else { return }
        let start = Date.now
        historyGapStartedAt = start
        historyGapReason = reason
        historyEventHandler?(.gap(start: start, end: nil, reason: reason))
    }

    private func endHistoryGapIfNeeded() {
        guard let start = historyGapStartedAt else { return }
        let reason = historyGapReason ?? .unavailable
        historyGapStartedAt = nil
        historyGapReason = nil
        historyEventHandler?(.gap(start: start, end: .now, reason: reason))
    }
}
