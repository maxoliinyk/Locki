//
//  ExplorationEngineTests.swift
//  LockiTests
//
//  Created by Max Oliinyk on 06.05.2026.
//

import Foundation
import Testing
@testable import Locki

@Suite("Street-precise exploration engine")
struct ExplorationEngineTests {
    private let now = Date(timeIntervalSinceReferenceDate: 10_000)
    private let engine = ExplorationEngine()

    @Test("Coverage cells use zoom 21 Mercator addressing")
    func coverageCellAddressing() {
        let origin = CoverageCell.containing(GeoCoordinate(latitude: 0, longitude: 0), zoom: 21)

        #expect(origin.x == 1 << 20)
        #expect(origin.y == 1 << 20)
        #expect(origin.zoom == 21)
        #expect(abs(origin.centerCoordinate.latitude) < 0.001)
        #expect(abs(origin.centerCoordinate.longitude) < 0.001)
    }

    @Test("Coverage masks handle boundary bits and idempotent union")
    func coverageMaskBoundaries() {
        var mask = CoverageMask()
        let insertedFirst = mask.insert(localX: 0, localY: 0)
        let insertedLast = mask.insert(localX: 63, localY: 63)
        let insertedDuplicate = mask.insert(localX: 63, localY: 63)
        #expect(insertedFirst)
        #expect(insertedLast)
        #expect(!insertedDuplicate)
        #expect(mask.contains(localX: 0, localY: 0))
        #expect(mask.contains(localX: 63, localY: 63))
        #expect(mask.setBitCount == 2)

        var copy = CoverageMask()
        let firstUnionCount = copy.formUnion(mask)
        let secondUnionCount = copy.formUnion(mask)
        #expect(firstUnionCount == 2)
        #expect(secondUnionCount == 0)
    }

    @Test("Cells split cleanly across chunk boundaries")
    func chunkBoundary() {
        var delta = CoverageDelta(unlockedAt: now)
        delta.insert(CoverageCell(x: 63, y: 63, zoom: 21))
        delta.insert(CoverageCell(x: 64, y: 64, zoom: 21))

        #expect(delta.chunks.count == 2)
        #expect(delta.chunks[CoverageChunkKey(x: 0, y: 0, zoom: 15)]?.setBitCount == 1)
        #expect(delta.chunks[CoverageChunkKey(x: 1, y: 1, zoom: 15)]?.setBitCount == 1)
    }

    @Test("Location filter rejects approximate, inaccurate, stale, future, and flight-speed samples")
    func rejectsUntrustworthySamples() {
        let coordinate = GeoCoordinate(latitude: 52.5200, longitude: 13.4050)
        let valid = sample(coordinate: coordinate, accuracy: 8, speed: 1.4, timestamp: now)

        #expect(engine.acceptedSample(valid, now: now))
        #expect(!engine.acceptedSample(sample(coordinate: coordinate, accuracy: 8, timestamp: now, precise: false), now: now))
        #expect(!engine.acceptedSample(sample(coordinate: coordinate, accuracy: 35.1, timestamp: now), now: now))
        #expect(!engine.acceptedSample(sample(coordinate: coordinate, accuracy: 8, timestamp: now.addingTimeInterval(-121)), now: now))
        #expect(!engine.acceptedSample(sample(coordinate: coordinate, accuracy: 8, timestamp: now.addingTimeInterval(11)), now: now))
        #expect(!engine.acceptedSample(sample(coordinate: coordinate, accuracy: 8, speed: 80.1, timestamp: now), now: now))
    }

    @Test("Reveal radius shrinks conservatively as uncertainty rises")
    func accuracyScaledRadius() {
        let coordinate = GeoCoordinate(latitude: 52.5200, longitude: 13.4050)

        #expect(engine.revealRadius(for: sample(coordinate: coordinate, accuracy: 0, timestamp: now)) == 20)
        #expect(engine.revealRadius(for: sample(coordinate: coordinate, accuracy: 20, timestamp: now)) == 16)
        #expect(engine.revealRadius(for: sample(coordinate: coordinate, accuracy: 35, timestamp: now)) == 10)
    }

    @Test("Plausible movement produces a continuous corridor")
    func plausibleMovementConnects() {
        let start = GeoCoordinate(latitude: 52.5200, longitude: 13.4050)
        let end = GeoCoordinate(latitude: 52.5200, longitude: 13.4062)
        let previous = sample(coordinate: start, accuracy: 6, speed: 4, timestamp: now)
        let current = sample(coordinate: end, accuracy: 6, speed: 4, timestamp: now.addingTimeInterval(20))

        let connected = engine.process(sample: current, previous: previous, now: now.addingTimeInterval(20))
        let isolated = engine.process(sample: current, previous: nil, now: now.addingTimeInterval(20))

        #expect(bitCount(connected) > bitCount(isolated))
        #expect(bitCount(connected) > 10)
    }

    @Test("Teleport and delayed samples never create long connectors")
    func discontinuitiesRemainIsolated() {
        let start = sample(
            coordinate: GeoCoordinate(latitude: 52.5200, longitude: 13.4050),
            accuracy: 5,
            speed: 1,
            timestamp: now
        )
        let far = sample(
            coordinate: GeoCoordinate(latitude: 52.6200, longitude: 13.5050),
            accuracy: 5,
            speed: 1,
            timestamp: now.addingTimeInterval(10)
        )
        let delayed = sample(
            coordinate: GeoCoordinate(latitude: 52.5210, longitude: 13.4060),
            accuracy: 5,
            speed: 1,
            timestamp: now.addingTimeInterval(31)
        )

        #expect(engine.process(sample: far, previous: start, now: far.timestamp) == engine.process(sample: far, previous: nil, now: far.timestamp))
        #expect(engine.process(sample: delayed, previous: start, now: delayed.timestamp) == engine.process(sample: delayed, previous: nil, now: delayed.timestamp))
    }

    @Test("Antimeridian interpolation takes the short path")
    func antimeridianUsesShortPath() {
        let previous = sample(
            coordinate: GeoCoordinate(latitude: 0, longitude: 179.9998),
            accuracy: 5,
            speed: 4,
            timestamp: now
        )
        let current = sample(
            coordinate: GeoCoordinate(latitude: 0, longitude: -179.9998),
            accuracy: 5,
            speed: 4,
            timestamp: now.addingTimeInterval(12)
        )
        let delta = engine.process(sample: current, previous: previous, now: current.timestamp)

        let chunkXValues = Set(delta.chunks.keys.map(\.x))
        let maximumChunkX = (1 << engine.configuration.chunkZoom) - 1

        #expect(chunkXValues == [0, maximumChunkX])
        #expect(delta.chunks.count <= 4)
        #expect(bitCount(delta) < 100)
    }

    private func sample(
        coordinate: GeoCoordinate,
        accuracy: Double,
        speed: Double? = nil,
        timestamp: Date,
        precise: Bool = true
    ) -> ExplorationLocationSample {
        ExplorationLocationSample(
            coordinate: coordinate,
            horizontalAccuracyMeters: accuracy,
            speedMetersPerSecond: speed,
            timestamp: timestamp,
            hasPreciseAccuracy: precise
        )
    }

    private func bitCount(_ delta: CoverageDelta) -> Int {
        delta.chunks.values.reduce(0) { $0 + $1.setBitCount }
    }
}
