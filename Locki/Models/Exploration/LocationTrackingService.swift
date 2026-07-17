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
final class LocationTrackingService: NSObject, CLLocationManagerDelegate, OneShotLocationProviding {
    private(set) var state: LocationTrackingState
    private(set) var authorizationStatus: CLAuthorizationStatus
    private(set) var accuracyAuthorization: CLAccuracyAuthorization
    private(set) var continuousBackgroundTrackingEnabled: Bool
    private(set) var historyTrackingEnabled: Bool
    private(set) var trackingMode: TrackingMode

    @ObservationIgnored var deltaHandler: ((CoverageDelta) -> Void)?
    @ObservationIgnored var pathAnchorHandler: ((PathAnchor) -> Void)?
    @ObservationIgnored var pathAnchorPurgeHandler: (() -> Void)?
    @ObservationIgnored var historyEventHandler: ((HistoryEvent) -> Void)?

    @ObservationIgnored private let locationManager: CLLocationManager
    @ObservationIgnored private let engine: ExplorationEngine
    @ObservationIgnored private let sparseAnchorPolicy: SparsePathAnchorPolicy
    @ObservationIgnored private var previousSample: ExplorationLocationSample?
    @ObservationIgnored private var previousAnchorSample: ExplorationLocationSample?
    @ObservationIgnored private var previousAnchorMotion: PathMotionKind?
    @ObservationIgnored private var pathSessionID: UUID?
    @ObservationIgnored private var currentPathMotion: PathMotionKind?
    @ObservationIgnored private var stationaryStartedAt: Date?
    @ObservationIgnored private var standardUpdatesRunning = false
    @ObservationIgnored private var significantChangeMonitoringRunning = false
    @ObservationIgnored private var visitMonitoringRunning = false
    @ObservationIgnored private var applicationIsActive = true
    @ObservationIgnored private var historyGapStartedAt: Date?
    @ObservationIgnored private var historyGapReason: HistoryGapReason?
    @ObservationIgnored private var historyServiceSession: CLServiceSession?
    @ObservationIgnored private var backgroundActivitySession: CLBackgroundActivitySession?
    @ObservationIgnored private var liveUpdateTask: Task<Void, Never>?
    @ObservationIgnored private var oneShotRequests: [UUID: OneShotRequest] = [:]

    private static let fullAccuracyPurposeKey = "ExplorationPrecision"
    private static let continuousBackgroundTrackingKey = "exploration.continuousBackgroundTracking"
    private static let trackingModeKey = "history.trackingMode"
    private static let historyTrackingKey = "history.enabled"

    private struct OneShotRequest {
        let continuation: CheckedContinuation<Bool, Never>
        let timeoutTask: Task<Void, Never>
    }

    init(
        locationManager: CLLocationManager = CLLocationManager(),
        engine: ExplorationEngine = ExplorationEngine(),
        sparseAnchorPolicy: SparsePathAnchorPolicy = SparsePathAnchorPolicy()
    ) {
        self.locationManager = locationManager
        self.engine = engine
        self.sparseAnchorPolicy = sparseAnchorPolicy
        authorizationStatus = locationManager.authorizationStatus
        accuracyAuthorization = locationManager.accuracyAuthorization
        let legacyContinuous = UserDefaults.standard.bool(forKey: Self.continuousBackgroundTrackingKey)
        let resolvedMode = Self.resolvedTrackingMode(
            storedMode: UserDefaults.standard.string(forKey: Self.trackingModeKey),
            legacyContinuous: legacyContinuous
        )
        trackingMode = resolvedMode
        continuousBackgroundTrackingEnabled = resolvedMode == .detailed
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

    nonisolated static func resolvedTrackingMode(
        storedMode: String?,
        legacyContinuous: Bool
    ) -> TrackingMode {
        storedMode.flatMap(TrackingMode.init(rawValue:))
            ?? (legacyContinuous ? .detailed : .efficient)
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
        setTrackingMode(enabled ? .detailed : .efficient)
    }

    func setTrackingMode(_ mode: TrackingMode) {
        trackingMode = mode
        continuousBackgroundTrackingEnabled = mode == .detailed
        UserDefaults.standard.set(mode.rawValue, forKey: Self.trackingModeKey)
        UserDefaults.standard.set(mode == .detailed, forKey: Self.continuousBackgroundTrackingKey)

        if mode == .detailed, authorizationStatus != .authorizedAlways {
            requestAlwaysLocationAccess()
        }
        updateLocationDelivery()
    }

    func setHistoryTrackingEnabled(_ enabled: Bool) {
        historyTrackingEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.historyTrackingKey)
        if enabled {
            if historyServiceSession == nil {
                historyServiceSession = CLServiceSession(
                    authorization: .always,
                    fullAccuracyPurposeKey: Self.fullAccuracyPurposeKey
                )
            }
            startVisitMonitoring()
            beginLocationUpdates()
        } else {
            historyServiceSession?.invalidate()
            historyServiceSession = nil
            stopVisitMonitoring()
            stopSignificantChangeMonitoring()
            endPathSession()
            pathAnchorPurgeHandler?()
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
                endPathSession()
                state = .unavailable(.authorizationDenied)
            case .restricted:
                beginHistoryGap(reason: .authorization)
                stopLocationUpdates()
                endPathSession()
                state = .unavailable(.authorizationRestricted)
            @unknown default:
                stopLocationUpdates()
                state = .failed
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            let source: PathAnchorSource? = if applicationIsActive {
                nil
            } else if oneShotRequests.isEmpty {
                .significantChange
            } else {
                .backgroundOneShot
            }
            let accepted = consume(locations, anchorSource: source)
            if accepted { finishAllOneShotRequests(success: true) }
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
            endPathSession()
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

        if historyTrackingEnabled, !significantChangeMonitoringRunning {
            locationManager.startMonitoringSignificantLocationChanges()
            significantChangeMonitoringRunning = true
        }
        if historyTrackingEnabled { startVisitMonitoring() }

        accuracyAuthorization = locationManager.accuracyAuthorization
        guard accuracyAuthorization == .fullAccuracy else {
            beginHistoryGap(reason: .reducedAccuracy)
            stopStandardUpdates()
            endPathSession()
            state = .requiresPreciseLocation
            return
        }
        endHistoryGapIfNeeded()

        updateLocationDelivery()
        state = .active
    }

    private func updateLocationDelivery() {
        guard hasLocationAccess, accuracyAuthorization == .fullAccuracy else { return }

        locationManager.distanceFilter = ProcessInfo.processInfo.isLowPowerModeEnabled ? 25 : 10

        let shouldRunStandardUpdates = applicationIsActive || continuousBackgroundTrackingEnabled
        if shouldRunStandardUpdates, !standardUpdatesRunning {
            startLiveUpdates()
            standardUpdatesRunning = true
        } else if !shouldRunStandardUpdates, standardUpdatesRunning {
            stopStandardUpdates()
        }
        if continuousBackgroundTrackingEnabled, historyTrackingEnabled {
            if backgroundActivitySession == nil { backgroundActivitySession = CLBackgroundActivitySession() }
        } else {
            backgroundActivitySession?.invalidate()
            backgroundActivitySession = nil
        }
    }

    private func stopLocationUpdates() {
        stopStandardUpdates()
        backgroundActivitySession?.invalidate()
        backgroundActivitySession = nil
        stopSignificantChangeMonitoring()
        stopVisitMonitoring()
        locationManager.allowsBackgroundLocationUpdates = false
        locationManager.showsBackgroundLocationIndicator = false
        previousSample = nil
        endPathSession()
        finishAllOneShotRequests(success: false)
    }

    private func stopStandardUpdates() {
        if standardUpdatesRunning {
            liveUpdateTask?.cancel()
            liveUpdateTask = nil
            standardUpdatesRunning = false
        }
        locationManager.allowsBackgroundLocationUpdates = false
        locationManager.showsBackgroundLocationIndicator = false
        previousSample = nil
    }

    @discardableResult
    private func consume(_ locations: [CLLocation]) -> Bool {
        consume(locations, anchorSource: nil)
    }

    @discardableResult
    private func consume(_ locations: [CLLocation], anchorSource: PathAnchorSource?) -> Bool {
        guard accuracyAuthorization == .fullAccuracy else {
            endPathSession()
            state = .requiresPreciseLocation
            return false
        }

        var acceptedAny = false
        for location in locations.sorted(by: { $0.timestamp < $1.timestamp }) {
            let sample = ExplorationLocationSample(location: location, hasPreciseAccuracy: true)
            let delta = engine.process(sample: sample, previous: previousSample)
            let directSampleAccepted = engine.acceptedSample(sample)

            if directSampleAccepted {
                acceptedAny = true
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
            }
            if let anchorSource,
               historyTrackingEnabled,
               sparseAnchorPolicy.accepts(sample) {
                emitPathAnchor(sample, source: anchorSource)
                acceptedAny = true
            }
            if !delta.isEmpty {
                deltaHandler?(delta)
            }
        }
        return acceptedAny
    }

    func updatePathMotion(_ activity: MotionActivitySample) {
        let motion = PathMotionKind(activity.kind)
        if activity.isReliableStationary {
            stationaryStartedAt = min(stationaryStartedAt ?? activity.startedAt, activity.startedAt)
        } else if activity.isReliableMovement {
            if let stationaryStartedAt,
               activity.startedAt.timeIntervalSince(stationaryStartedAt)
                >= PathMatchingConfiguration.standard.stationaryBoundaryInterval {
                endPathSession()
            }
            stationaryStartedAt = nil
        }
        currentPathMotion = motion
    }

    func endPathSession() {
        previousAnchorSample = nil
        previousAnchorMotion = nil
        pathSessionID = nil
    }

    private func emitPathAnchor(_ sample: ExplorationLocationSample, source: PathAnchorSource) {
        if let previousAnchorSample,
           sample.timestamp == previousAnchorSample.timestamp,
           sample.coordinate.distance(to: previousAnchorSample.coordinate) < 1 {
            return
        }
        if let stationaryStartedAt,
           sample.timestamp.timeIntervalSince(stationaryStartedAt)
            >= PathMatchingConfiguration.standard.stationaryBoundaryInterval {
            endPathSession()
            self.stationaryStartedAt = nil
        }
        if let previousAnchorSample,
           !sparseAnchorPolicy.canContinue(
                from: previousAnchorSample,
                previousMotion: previousAnchorMotion,
                to: sample,
                motion: currentPathMotion
           ) {
            endPathSession()
        }
        let sessionID = pathSessionID ?? UUID()
        pathSessionID = sessionID
        pathAnchorHandler?(
            PathAnchor(
                sample: sample,
                source: source,
                motionKind: currentPathMotion,
                sessionID: sessionID
            )
        )
        previousAnchorSample = sample
        previousAnchorMotion = currentPathMotion
    }

    func requestOneShotLocation(timeout: Duration = .seconds(12)) async -> Bool {
        guard hasAlwaysLocationAccess else { return false }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) }
                    catch { return }
                    self?.finishOneShotRequest(id: id, success: false)
                }
                oneShotRequests[id] = OneShotRequest(continuation: continuation, timeoutTask: timeoutTask)
                locationManager.requestLocation()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishOneShotRequest(id: id, success: false) }
        }
    }

    private func startLiveUpdates() {
        liveUpdateTask?.cancel()
        liveUpdateTask = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates(.otherNavigation) {
                    guard let self, !Task.isCancelled else { return }
                    if update.authorizationDenied || update.authorizationDeniedGlobally {
                        state = .unavailable(.authorizationDenied)
                        continue
                    }
                    if update.stationary {
                        state = .stationary
                        if historyTrackingEnabled { historyEventHandler?(.dwellCheck(.now)) }
                    }
                    if let location = update.location { consume([location], anchorSource: nil) }
                }
            } catch is CancellationError {
                // Expected when foreground or detailed tracking ends.
            } catch {
                self?.state = .failed
            }
        }
    }

    private func finishOneShotRequest(id: UUID, success: Bool) {
        guard let request = oneShotRequests.removeValue(forKey: id) else { return }
        request.timeoutTask.cancel()
        request.continuation.resume(returning: success)
    }

    private func finishAllOneShotRequests(success: Bool) {
        for id in Array(oneShotRequests.keys) { finishOneShotRequest(id: id, success: success) }
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

    private func stopSignificantChangeMonitoring() {
        guard significantChangeMonitoringRunning else { return }
        locationManager.stopMonitoringSignificantLocationChanges()
        significantChangeMonitoringRunning = false
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
