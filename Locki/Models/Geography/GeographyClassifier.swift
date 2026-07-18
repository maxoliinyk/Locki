//
//  GeographyClassifier.swift
//  Locki
//
//  Created by Max Oliinyk on 18.07.2026.
//

import Foundation

nonisolated struct GeographyPolygon: Hashable, Sendable {
    let rings: [[GeoCoordinate]]
}
nonisolated struct GeographyFeature<Value: Hashable & Sendable>: Hashable, Sendable {
    let value: Value
    let polygons: [GeographyPolygon]
}

nonisolated struct GeographyClassifier: Sendable {
    let datasetVersion: String

    func classify(
        coordinate: GeoCoordinate,
        horizontalAccuracyMeters: Double,
        countries: [GeographyFeature<GeographyCountry>],
        cities: [GeographyFeature<GeographyCity>]
    ) -> GeographyClassification {
        guard coordinate.isValid, horizontalAccuracyMeters.isFinite, horizontalAccuracyMeters >= 0 else {
            return GeographyClassification(
                country: nil,
                city: nil,
                datasetVersion: datasetVersion,
                status: .outside
            )
        }

        let countryMatch = match(
            coordinate: coordinate,
            horizontalAccuracyMeters: horizontalAccuracyMeters,
            features: countries
        )
        let cityMatch = match(
            coordinate: coordinate,
            horizontalAccuracyMeters: horizontalAccuracyMeters,
            features: cities
        )

        let status: GeographyClassificationStatus
        if countryMatch.isAmbiguous || cityMatch.isAmbiguous {
            status = .ambiguous
        } else if countryMatch.value == nil {
            status = .outside
        } else {
            status = .certain
        }

        return GeographyClassification(
            country: countryMatch.value,
            city: cityMatch.value,
            datasetVersion: datasetVersion,
            status: status
        )
    }

    private func match<Value: Hashable & Sendable>(
        coordinate: GeoCoordinate,
        horizontalAccuracyMeters: Double,
        features: [GeographyFeature<Value>]
    ) -> (value: Value?, isAmbiguous: Bool) {
        var containing: [Value] = []
        var touchesAccuracyRadius = false

        for feature in features {
            let contains = feature.polygons.contains { polygonContains(coordinate, polygon: $0) }
            let boundaryDistance = feature.polygons
                .map { distanceToBoundary(coordinate, polygon: $0) }
                .min() ?? .infinity
            if contains {
                containing.append(feature.value)
            }
            if boundaryDistance <= horizontalAccuracyMeters {
                touchesAccuracyRadius = true
            }
        }

        if containing.count == 1, !touchesAccuracyRadius {
            return (containing[0], false)
        }
        if containing.count > 1 || touchesAccuracyRadius {
            return (nil, true)
        }
        return (nil, false)
    }

    private func polygonContains(_ point: GeoCoordinate, polygon: GeographyPolygon) -> Bool {
        guard let exterior = polygon.rings.first, ringContains(point, ring: exterior) else {
            return false
        }
        return !polygon.rings.dropFirst().contains { ringContains(point, ring: $0) }
    }

    private func ringContains(_ point: GeoCoordinate, ring: [GeoCoordinate]) -> Bool {
        guard ring.count >= 4 else { return false }
        var inside = false
        for index in ring.indices {
            let previousIndex = index == ring.startIndex ? ring.index(before: ring.endIndex) : ring.index(before: index)
            let first = localCoordinate(ring[previousIndex], relativeTo: point)
            let second = localCoordinate(ring[index], relativeTo: point)
            let crossesLatitude = (first.y > 0) != (second.y > 0)
            if crossesLatitude {
                let longitudeAtLatitude = (second.x - first.x) * (-first.y) / (second.y - first.y) + first.x
                if longitudeAtLatitude > 0 {
                    inside.toggle()
                }
            }
        }
        return inside
    }

    private func distanceToBoundary(_ point: GeoCoordinate, polygon: GeographyPolygon) -> Double {
        polygon.rings
            .flatMap { ring in
                zip(ring, ring.dropFirst()).map { start, end in
                    distanceFromOriginToSegment(
                        start: localCoordinate(start, relativeTo: point),
                        end: localCoordinate(end, relativeTo: point)
                    )
                }
            }
            .min() ?? .infinity
    }

    private func localCoordinate(
        _ coordinate: GeoCoordinate,
        relativeTo origin: GeoCoordinate
    ) -> (x: Double, y: Double) {
        var longitudeDelta = coordinate.longitude - origin.longitude
        if longitudeDelta > 180 { longitudeDelta -= 360 }
        if longitudeDelta < -180 { longitudeDelta += 360 }
        let latitudeRadians = origin.latitude * .pi / 180
        let metersPerDegree = 111_195.0
        return (
            longitudeDelta * cos(latitudeRadians) * metersPerDegree,
            (coordinate.latitude - origin.latitude) * metersPerDegree
        )
    }

    private func distanceFromOriginToSegment(
        start: (x: Double, y: Double),
        end: (x: Double, y: Double)
    ) -> Double {
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        let lengthSquared = deltaX * deltaX + deltaY * deltaY
        guard lengthSquared > 0 else { return hypot(start.x, start.y) }
        let projection = max(0, min(1, -(start.x * deltaX + start.y * deltaY) / lengthSquared))
        return hypot(start.x + projection * deltaX, start.y + projection * deltaY)
    }
}
