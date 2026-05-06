//
//  MapViewModel.swift
//  Locki
//
//  Created by Max Oliinyk on 06.05.2026.
//

import MapKit
import Observation
import SwiftUI

@MainActor
@Observable
final class MapViewModel: NSObject, CLLocationManagerDelegate {
    var cameraPosition: MapCameraPosition
    var trackingMode: TrackingMode = .paused
    var exploredPlacesCount = 0
    var routeDistance = Measurement(value: 0, unit: UnitLength.kilometers)
    var showsUserLocation = false
    var isCameraFollowingUser = false
    private(set) var locationAuthorizationStatus: CLAuthorizationStatus

    @ObservationIgnored private let locationManager = CLLocationManager()
    @ObservationIgnored private var lastRouteLocation: CLLocation?

    override init() {
        cameraPosition = .region(.defaultLockiRegion)
        locationAuthorizationStatus = locationManager.authorizationStatus

        super.init()

        locationManager.delegate = self
        updateLocationState(for: locationManager.authorizationStatus)
    }

    var statusTitle: String {
        guard hasLocationAccess else {
            return locationPermissionTitle
        }

        return trackingMode.title
    }

    var statusDescription: String {
        guard hasLocationAccess else {
            return locationPermissionDescription
        }

        return trackingMode.description
    }

    var statusSystemImage: String {
        guard hasLocationAccess else {
            return locationPermissionSystemImage
        }

        return trackingMode.systemImage
    }

    var statusTint: Color {
        guard hasLocationAccess else {
            return .orange
        }

        return trackingMode.tint
    }

    var canRecenterMap: Bool {
        hasLocationAccess
    }

    var locationPermissionTitle: String {
        switch locationAuthorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            "Location allowed"
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

    var locationPermissionDescription: String {
        switch locationAuthorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            "Locki can show your current position on the map."
        case .denied:
            "Allow location access in Settings to show your position on the map."
        case .restricted:
            "Location access is restricted on this device."
        case .notDetermined:
            "Allow location access to show your current position on the map."
        @unknown default:
            "Locki cannot determine location permission right now."
        }
    }

    var locationPermissionSystemImage: String {
        switch locationAuthorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            "location.fill"
        case .denied, .restricted:
            "location.slash"
        case .notDetermined:
            "location.circle"
        @unknown default:
            "questionmark.circle"
        }
    }

    var formattedRouteDistance: String {
        routeDistance.formatted(.measurement(width: .abbreviated, usage: .road))
    }

    func startStandardTracking() {
        startLocationUpdates(mode: .standard)
    }

    func startRoute() {
        routeDistance = Measurement(value: 0, unit: UnitLength.kilometers)
        lastRouteLocation = nil
        startLocationUpdates(mode: .activeRoute)
    }

    func pauseTracking() {
        trackingMode = .paused
        lastRouteLocation = nil
        locationManager.stopUpdatingLocation()
    }

    func requestLocationAccess() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        default:
            updateLocationState(for: locationManager.authorizationStatus)
        }
    }

    func recenterMap() {
        guard hasLocationAccess else {
            requestLocationAccess()
            return
        }

        showsUserLocation = true
        isCameraFollowingUser = true
        cameraPosition = .userLocation(followsHeading: false, fallback: .region(.defaultLockiRegion))
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            updateRouteDistance(with: locations)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            updateLocationState(for: manager.authorizationStatus)
            if hasLocationAccess, trackingMode != .paused {
                startLocationUpdates(mode: trackingMode)
            }
        }
    }

    private var hasLocationAccess: Bool {
        switch locationAuthorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            true
        case .denied, .restricted, .notDetermined:
            false
        @unknown default:
            false
        }
    }

    private func updateLocationState(for authorizationStatus: CLAuthorizationStatus) {
        locationAuthorizationStatus = authorizationStatus

        switch authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            showsUserLocation = true
            isCameraFollowingUser = true
            cameraPosition = .userLocation(followsHeading: false, fallback: .region(.defaultLockiRegion))
        case .denied, .restricted, .notDetermined:
            showsUserLocation = false
            isCameraFollowingUser = false
            cameraPosition = .region(.defaultLockiRegion)
        @unknown default:
            showsUserLocation = false
            isCameraFollowingUser = false
            cameraPosition = .region(.defaultLockiRegion)
        }
    }

    private func startLocationUpdates(mode: TrackingMode) {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            trackingMode = mode
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            trackingMode = mode
            showsUserLocation = true
            locationManager.desiredAccuracy = mode.desiredAccuracy
            locationManager.distanceFilter = mode.distanceFilter
            locationManager.startUpdatingLocation()
            recenterMap()
        case .denied, .restricted:
            updateLocationState(for: locationManager.authorizationStatus)
        @unknown default:
            updateLocationState(for: locationManager.authorizationStatus)
        }
    }

    private func updateRouteDistance(with locations: [CLLocation]) {
        guard trackingMode == .activeRoute else {
            return
        }

        for location in locations where location.horizontalAccuracy >= 0 {
            if let lastRouteLocation {
                let addedDistance = location.distance(from: lastRouteLocation)
                routeDistance = routeDistance + Measurement(value: addedDistance, unit: UnitLength.meters)
            }

            lastRouteLocation = location
        }
    }
}

private extension MKCoordinateRegion {
    static let defaultLockiRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090),
        span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
    )
}

private extension TrackingMode {
    var systemImage: String {
        switch self {
        case .paused:
            "pause.circle.fill"
        case .standard:
            "location.fill"
        case .activeRoute:
            "point.topleft.down.curvedto.point.bottomright.up"
        }
    }

    var tint: Color {
        switch self {
        case .paused:
            .secondary
        case .standard:
            .blue
        case .activeRoute:
            .green
        }
    }

    var desiredAccuracy: CLLocationAccuracy {
        switch self {
        case .paused:
            kCLLocationAccuracyThreeKilometers
        case .standard:
            kCLLocationAccuracyHundredMeters
        case .activeRoute:
            kCLLocationAccuracyBest
        }
    }

    var distanceFilter: CLLocationDistance {
        switch self {
        case .paused:
            kCLDistanceFilterNone
        case .standard:
            100
        case .activeRoute:
            10
        }
    }
}
