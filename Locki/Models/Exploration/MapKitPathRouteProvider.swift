//
//  MapKitPathRouteProvider.swift
//  Locki
//
//  Created by Max Oliinyk on 17.07.2026.
//

import CoreLocation
import Foundation
import MapKit

@MainActor
final class MapKitPathRouteProvider: PathRouteProviding {
    func routes(for request: PathRouteRequest) async throws -> [PathRouteCandidate] {
        var candidates: [PathRouteCandidate] = []
        var lastError: (any Error)?

        for mode in request.modes.prefix(2) {
            try Task.checkCancellation()
            do {
                candidates += try await routes(for: request, mode: mode, includeDepartureDate: true)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                guard mode != .transit else { continue }
                do {
                    candidates += try await routes(for: request, mode: mode, includeDepartureDate: false)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                }
            }
        }

        if candidates.isEmpty, let lastError { throw lastError }
        return candidates
    }

    private func routes(
        for request: PathRouteRequest,
        mode: PathTravelMode,
        includeDepartureDate: Bool
    ) async throws -> [PathRouteCandidate] {
        let directionsRequest = MKDirections.Request()
        directionsRequest.source = mapItem(for: request.source)
        directionsRequest.destination = mapItem(for: request.destination)
        directionsRequest.transportType = mode.mapKitTransportType
        directionsRequest.requestsAlternateRoutes = true
        if includeDepartureDate { directionsRequest.departureDate = request.departureDate }

        let directions = MKDirections(request: directionsRequest)
        let response = try await directions.calculate()
        return response.routes.compactMap { route in
            let coordinates = coordinates(from: route.polyline)
            guard coordinates.count >= 2 else { return nil }
            return PathRouteCandidate(
                coordinates: coordinates,
                distanceMeters: route.distance,
                expectedTravelTime: route.expectedTravelTime,
                mode: mode
            )
        }
    }

    private func mapItem(for coordinate: GeoCoordinate) -> MKMapItem {
        MKMapItem(
            location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude),
            address: nil
        )
    }

    private func coordinates(from polyline: MKPolyline) -> [GeoCoordinate] {
        guard polyline.pointCount > 0 else { return [] }
        var coordinates = Array(
            repeating: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            count: polyline.pointCount
        )
        coordinates.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            polyline.getCoordinates(baseAddress, range: NSRange(location: 0, length: polyline.pointCount))
        }
        return coordinates.map(GeoCoordinate.init).filter(\.isValid)
    }
}

private extension PathTravelMode {
    var mapKitTransportType: MKDirectionsTransportType {
        switch self {
        case .walking: .walking
        case .cycling: .cycling
        case .automobile: .automobile
        case .transit: .transit
        }
    }
}
