//
//  MapKitGapRouteProvider.swift
//  Locki
//
//  Created by Max Oliinyk on 18.07.2026.
//

import CoreLocation
import MapKit

@MainActor
protocol GapRouteProviding: AnyObject {
    func routes(
        from source: GeoCoordinate,
        to destination: GeoCoordinate,
        departureDate: Date,
        mode: HistoryGapTravelMode
    ) async throws -> [GapRouteCandidate]
}

@MainActor
final class MapKitGapRouteProvider: GapRouteProviding {
    func routes(
        from source: GeoCoordinate,
        to destination: GeoCoordinate,
        departureDate: Date,
        mode: HistoryGapTravelMode
    ) async throws -> [GapRouteCandidate] {
        let request = MKDirections.Request()
        request.source = mapItem(for: source)
        request.destination = mapItem(for: destination)
        request.departureDate = departureDate
        request.transportType = mode.mapKitTransportType
        request.requestsAlternateRoutes = true
        let response = try await MKDirections(request: request).calculate()
        return response.routes.compactMap { route in
            let coordinates = coordinates(from: route.polyline)
            guard coordinates.count >= 2 else { return nil }
            return GapRouteCandidate(
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
        var values = Array(
            repeating: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            count: polyline.pointCount
        )
        values.withUnsafeMutableBufferPointer { buffer in
            guard let address = buffer.baseAddress else { return }
            polyline.getCoordinates(address, range: NSRange(location: 0, length: polyline.pointCount))
        }
        return values.map(GeoCoordinate.init).filter(\.isValid)
    }
}

private extension HistoryGapTravelMode {
    var mapKitTransportType: MKDirectionsTransportType {
        switch self {
        case .walking: .walking
        case .cycling: .cycling
        case .automobile: .automobile
        case .transit: .transit
        }
    }
}
