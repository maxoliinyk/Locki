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
    var mapStyle: LockiMapStyle = .standard
    var showsUserLocation = false
    var isCameraFollowingUser = false
    private(set) var locationAuthorizationStatus: CLAuthorizationStatus

    @ObservationIgnored private let locationManager = CLLocationManager()
    @ObservationIgnored private let geocoder = CLGeocoder()

    override init() {
        cameraPosition = .region(.defaultLockiRegion)
        locationAuthorizationStatus = locationManager.authorizationStatus

        super.init()

        locationManager.delegate = self
        updateLocationState(for: locationManager.authorizationStatus)

        Task {
            await updateFallbackRegionForCurrentLocale()
        }
    }

    var canRecenterMap: Bool {
        hasLocationAccess
    }

    var showsLocationOnboarding: Bool {
        !hasLocationAccess
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

    var locationPermissionButtonTitle: String {
        switch locationAuthorizationStatus {
        case .denied, .restricted:
            "Open Settings"
        default:
            "Enable Location"
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

    func requestLocationAccess() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            openAppSettings()
        default:
            updateLocationState(for: locationManager.authorizationStatus)
        }
    }

    func recenterMap() {
        guard hasLocationAccess else {
            return
        }

        showsUserLocation = true
        isCameraFollowingUser = true

        withAnimation(.easeInOut) {
            cameraPosition = .userLocation(followsHeading: false, fallback: .region(.defaultLockiRegion))
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            updateLocationState(for: manager.authorizationStatus)
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
        @unknown default:
            showsUserLocation = false
            isCameraFollowingUser = false
        }
    }

    private func openAppSettings() {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else {
            return
        }

        UIApplication.shared.open(settingsURL)
    }

    private func updateFallbackRegionForCurrentLocale() async {
        guard !hasLocationAccess,
              let region = Locale.current.region,
              let countryName = Locale.current.localizedString(forRegionCode: region.identifier) else {
            return
        }

        do {
            let placemarks = try await geocoder.geocodeAddressString(countryName)
            guard !hasLocationAccess,
                  let coordinate = placemarks.first?.location?.coordinate else {
                return
            }

            cameraPosition = .region(
                MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 8, longitudeDelta: 8)
                )
            )
        } catch {
            cameraPosition = .region(.defaultLockiRegion)
        }
    }
}

private extension MKCoordinateRegion {
    static let defaultLockiRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090),
        span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
    )
}
