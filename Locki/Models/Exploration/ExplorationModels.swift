//
//  ExplorationModels.swift
//  Locki
//
//  Created by Max Oliinyk on 06.05.2026.
//

import CoreLocation
import Foundation
import MapKit

nonisolated struct GeoCoordinate: Hashable, Sendable {
    static let maximumMercatorLatitude = 85.05112878

    let latitude: Double
    let longitude: Double

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    init(_ coordinate: CLLocationCoordinate2D) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    var locationCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var isValid: Bool {
        latitude.isFinite
            && longitude.isFinite
            && (-90...90).contains(latitude)
            && (-180...180).contains(longitude)
    }

    var clampedForMercator: GeoCoordinate {
        GeoCoordinate(
            latitude: min(max(latitude, -Self.maximumMercatorLatitude), Self.maximumMercatorLatitude),
            longitude: min(max(longitude, -180), 180)
        )
    }

    func distance(to other: GeoCoordinate) -> Double {
        let earthRadiusMeters = 6_371_000.0
        let latitude1 = latitude * .pi / 180
        let latitude2 = other.latitude * .pi / 180
        let latitudeDelta = (other.latitude - latitude) * .pi / 180
        let longitudeDelta = (other.longitude - longitude) * .pi / 180
        let a = sin(latitudeDelta / 2) * sin(latitudeDelta / 2)
            + cos(latitude1) * cos(latitude2)
            * sin(longitudeDelta / 2) * sin(longitudeDelta / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))

        return earthRadiusMeters * c
    }

    func interpolated(to other: GeoCoordinate, fraction: Double) -> GeoCoordinate {
        let longitudeDelta = normalizedLongitudeDelta(from: longitude, to: other.longitude)
        var interpolatedLongitude = longitude + longitudeDelta * fraction
        if interpolatedLongitude > 180 { interpolatedLongitude -= 360 }
        if interpolatedLongitude < -180 { interpolatedLongitude += 360 }

        return GeoCoordinate(
            latitude: latitude + (other.latitude - latitude) * fraction,
            longitude: interpolatedLongitude
        )
    }

    private func normalizedLongitudeDelta(from start: Double, to end: Double) -> Double {
        var delta = end - start
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return delta
    }
}

nonisolated struct ExplorationConfiguration: Hashable, Sendable {
    let coverageZoom: Int
    let chunkZoom: Int
    let minimumRevealRadiusMeters: Double
    let maximumRevealRadiusMeters: Double
    let revealRadiusBaseMeters: Double
    let accuracyRadiusPenalty: Double
    let featherMeters: Double
    let maximumHorizontalAccuracyMeters: Double
    let maximumSampleAge: TimeInterval
    let maximumConnectionAge: TimeInterval
    let futureTimestampTolerance: TimeInterval
    let maximumSpeedMetersPerSecond: Double
    let interpolationSpacingMeters: Double

    static let streetPrecise = ExplorationConfiguration(
        coverageZoom: 21,
        chunkZoom: 15,
        minimumRevealRadiusMeters: 10,
        maximumRevealRadiusMeters: 20,
        revealRadiusBaseMeters: 24,
        accuracyRadiusPenalty: 0.4,
        featherMeters: 8,
        maximumHorizontalAccuracyMeters: 35,
        maximumSampleAge: 120,
        maximumConnectionAge: 30,
        futureTimestampTolerance: 10,
        maximumSpeedMetersPerSecond: 80,
        interpolationSpacingMeters: 8
    )

    var cellsPerChunkSide: Int {
        1 << (coverageZoom - chunkZoom)
    }
}

nonisolated struct ExplorationLocationSample: Hashable, Sendable {
    let coordinate: GeoCoordinate
    let horizontalAccuracyMeters: Double
    let speedMetersPerSecond: Double?
    let timestamp: Date
    let hasPreciseAccuracy: Bool

    init(
        coordinate: GeoCoordinate,
        horizontalAccuracyMeters: Double,
        speedMetersPerSecond: Double? = nil,
        timestamp: Date,
        hasPreciseAccuracy: Bool = true
    ) {
        self.coordinate = coordinate
        self.horizontalAccuracyMeters = horizontalAccuracyMeters
        self.speedMetersPerSecond = speedMetersPerSecond
        self.timestamp = timestamp
        self.hasPreciseAccuracy = hasPreciseAccuracy
    }

    init(location: CLLocation, hasPreciseAccuracy: Bool) {
        self.init(
            coordinate: GeoCoordinate(location.coordinate),
            horizontalAccuracyMeters: location.horizontalAccuracy,
            speedMetersPerSecond: location.speed >= 0 ? location.speed : nil,
            timestamp: location.timestamp,
            hasPreciseAccuracy: hasPreciseAccuracy
        )
    }
}

nonisolated struct CoverageCell: Hashable, Sendable {
    let x: Int
    let y: Int
    let zoom: Int

    static func containing(_ coordinate: GeoCoordinate, zoom: Int) -> CoverageCell {
        let coordinate = coordinate.clampedForMercator
        let scale = Double(1 << zoom)
        let normalizedX = (coordinate.longitude + 180) / 360
        let latitudeRadians = coordinate.latitude * .pi / 180
        let normalizedY = (1 - log(tan(latitudeRadians) + 1 / cos(latitudeRadians)) / .pi) / 2
        let maxIndex = Int(scale) - 1

        return CoverageCell(
            x: min(max(Int(floor(normalizedX * scale)), 0), maxIndex),
            y: min(max(Int(floor(normalizedY * scale)), 0), maxIndex),
            zoom: zoom
        )
    }

    var centerCoordinate: GeoCoordinate {
        let scale = Double(1 << zoom)
        let longitude = (Double(x) + 0.5) / scale * 360 - 180
        let mercatorY = .pi * (1 - 2 * (Double(y) + 0.5) / scale)
        return GeoCoordinate(latitude: atan(sinh(mercatorY)) * 180 / .pi, longitude: longitude)
    }

    var mapRect: MKMapRect {
        let scale = Double(1 << zoom)
        let worldSize = MKMapSize.world.width
        let side = worldSize / scale
        return MKMapRect(x: Double(x) * side, y: Double(y) * side, width: side, height: side)
    }
}

nonisolated struct CoverageChunkKey: Hashable, Identifiable, Sendable {
    let x: Int
    let y: Int
    let zoom: Int

    var id: String { rawValue }
    var rawValue: String { "\(zoom)/\(x)/\(y)" }

    init(x: Int, y: Int, zoom: Int) {
        self.x = x
        self.y = y
        self.zoom = zoom
    }

    init?(rawValue: String) {
        let components = rawValue.split(separator: "/")
        guard components.count == 3,
              let zoom = Int(components[0]),
              let x = Int(components[1]),
              let y = Int(components[2]) else {
            return nil
        }
        self.init(x: x, y: y, zoom: zoom)
    }

    var mapRect: MKMapRect {
        let scale = Double(1 << zoom)
        let side = MKMapSize.world.width / scale
        return MKMapRect(x: Double(x) * side, y: Double(y) * side, width: side, height: side)
    }
}

nonisolated struct CoverageMask: Hashable, Sendable {
    static let cellCount = 4_096
    static let byteCount = cellCount / 8

    private(set) var data: Data

    init(data: Data = Data(repeating: 0, count: byteCount)) {
        if data.count == Self.byteCount {
            self.data = data
        } else {
            var normalized = Data(repeating: 0, count: Self.byteCount)
            normalized.replaceSubrange(0..<min(data.count, Self.byteCount), with: data.prefix(Self.byteCount))
            self.data = normalized
        }
    }

    var setBitCount: Int {
        data.reduce(0) { $0 + $1.nonzeroBitCount }
    }

    var isEmpty: Bool {
        !data.contains { $0 != 0 }
    }

    func contains(localX: Int, localY: Int) -> Bool {
        guard (0..<64).contains(localX), (0..<64).contains(localY) else { return false }
        let index = localY * 64 + localX
        return data[index / 8] & (1 << UInt8(index % 8)) != 0
    }

    @discardableResult
    mutating func insert(localX: Int, localY: Int) -> Bool {
        guard (0..<64).contains(localX), (0..<64).contains(localY) else { return false }
        let index = localY * 64 + localX
        let byteIndex = index / 8
        let bit = UInt8(1 << UInt8(index % 8))
        let wasSet = data[byteIndex] & bit != 0
        data[byteIndex] |= bit
        return !wasSet
    }

    @discardableResult
    mutating func formUnion(_ other: CoverageMask) -> Int {
        var added = 0
        for index in data.indices {
            let before = data[index]
            let after = before | other.data[index]
            added += (after ^ before).nonzeroBitCount
            data[index] = after
        }
        return added
    }
}

nonisolated struct CoverageChunkSnapshot: Hashable, Identifiable, Sendable {
    let key: CoverageChunkKey
    let mask: CoverageMask
    let revision: Int

    var id: String { key.rawValue }
}

nonisolated struct CoverageDelta: Hashable, Sendable {
    var chunks: [CoverageChunkKey: CoverageMask]
    var unlockedAt: Date

    init(chunks: [CoverageChunkKey: CoverageMask] = [:], unlockedAt: Date) {
        self.chunks = chunks
        self.unlockedAt = unlockedAt
    }

    var isEmpty: Bool { chunks.isEmpty }

    mutating func insert(_ cell: CoverageCell, configuration: ExplorationConfiguration = .streetPrecise) {
        let shift = configuration.coverageZoom - configuration.chunkZoom
        let side = 1 << shift
        let key = CoverageChunkKey(x: cell.x >> shift, y: cell.y >> shift, zoom: configuration.chunkZoom)
        let localX = cell.x & (side - 1)
        let localY = cell.y & (side - 1)
        var mask = chunks[key] ?? CoverageMask()
        mask.insert(localX: localX, localY: localY)
        chunks[key] = mask
    }

    mutating func formUnion(_ other: CoverageDelta) {
        for (key, otherMask) in other.chunks {
            var mask = chunks[key] ?? CoverageMask()
            mask.formUnion(otherMask)
            chunks[key] = mask
        }
        unlockedAt = max(unlockedAt, other.unlockedAt)
    }
}

nonisolated struct CoverageSnapshot: Hashable, Sendable {
    var chunks: [CoverageChunkKey: CoverageChunkSnapshot]
    var totalExploredCellCount: Int
    var lastUnlockDate: Date?
    var generation: Int

    static let empty = CoverageSnapshot(
        chunks: [:],
        totalExploredCellCount: 0,
        lastUnlockDate: nil,
        generation: 0
    )

    mutating func apply(_ delta: CoverageDelta) {
        var added = 0
        for (key, deltaMask) in delta.chunks {
            var mask = chunks[key]?.mask ?? CoverageMask()
            let newBits = mask.formUnion(deltaMask)
            guard newBits > 0 else { continue }
            added += newBits
            let revision = (chunks[key]?.revision ?? 0) + 1
            chunks[key] = CoverageChunkSnapshot(key: key, mask: mask, revision: revision)
        }
        guard added > 0 else { return }
        totalExploredCellCount += added
        lastUnlockDate = max(lastUnlockDate ?? .distantPast, delta.unlockedAt)
        generation += 1
    }
}

// Legacy zoom-based tile retained for one migration release.
nonisolated struct ExplorationTile: Hashable, Identifiable, Sendable {
    let x: Int
    let y: Int
    let zoom: Int

    var id: String { key }
    var key: String { "\(zoom)/\(x)/\(y)" }

    init(x: Int, y: Int, zoom: Int) {
        self.x = x
        self.y = y
        self.zoom = zoom
    }

    init?(key: String) {
        let components = key.split(separator: "/")
        guard components.count == 3,
              let zoom = Int(components[0]),
              let x = Int(components[1]),
              let y = Int(components[2]) else { return nil }
        self.init(x: x, y: y, zoom: zoom)
    }

    static func containing(_ coordinate: GeoCoordinate, zoom: Int) -> ExplorationTile {
        let cell = CoverageCell.containing(coordinate, zoom: zoom)
        return ExplorationTile(x: cell.x, y: cell.y, zoom: cell.zoom)
    }
}
