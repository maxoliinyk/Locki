//
//  PathMatchingEngineTests.swift
//  LockiTests
//
//  Created by Max Oliinyk on 17.07.2026.
//

import Foundation
import Testing
@testable import Locki

@Suite("Path matching engine")
struct PathMatchingEngineTests {
    private let now = Date(timeIntervalSinceReferenceDate: 20_000)
    private let engine = PathMatchingEngine()

    @Test("Quantized anchors retain cells and buckets instead of source coordinates")
    func quantizesAnchor() {
        let sample = ExplorationLocationSample(
            coordinate: GeoCoordinate(latitude: 52.520_123, longitude: 13.405_456),
            horizontalAccuracyMeters: 12.1,
            speedMetersPerSecond: 3.1,
            courseDegrees: 87,
            timestamp: now
        )

        let anchor = PathAnchor(sample: sample)

        #expect(anchor.coordinate != sample.coordinate)
        #expect(anchor.accuracyBucketMeters == 15)
        #expect(anchor.speedBucketMetersPerSecond == 4)
        #expect(anchor.courseBucketDegrees == 90)
    }

    @Test("A recent continuous sequence becomes a matching window")
    func buildsWindow() {
        let anchors = eastboundAnchors(count: 4)

        let window = engine.matchingWindow(from: anchors, now: now.addingTimeInterval(901))

        #expect(window.map(\.id) == anchors.map(\.id))
    }

    @Test("Expired and discontinuous anchors do not form a path")
    func rejectsExpiredAndDiscontinuousAnchors() {
        let expired = eastboundAnchors(count: 3, start: now.addingTimeInterval(-7 * 60 * 60))
        #expect(engine.matchingWindow(from: expired, now: now).isEmpty)

        var discontinuous = eastboundAnchors(count: 2)
        discontinuous.append(anchor(latitude: 53, longitude: 14, time: now.addingTimeInterval(700)))
        #expect(engine.matchingWindow(from: discontinuous, now: now.addingTimeInterval(701)).isEmpty)
    }

    @Test("Three aligned anchors with heading evidence accept one route")
    func acceptsAlignedRoute() {
        let anchors = eastboundAnchors(count: 3)
        let candidate = candidate(following: anchors)

        #expect(engine.decide(anchors: anchors, candidates: [candidate]) == .matched(candidate))
    }

    @Test("Three anchors without heading evidence wait for a fourth")
    func requiresMoreEvidenceForSingleRoute() {
        let anchors = eastboundAnchors(count: 3, course: nil)

        #expect(engine.decide(anchors: anchors, candidates: [candidate(following: anchors)]) == .needsMoreEvidence)
    }

    @Test("Equally plausible divergent routes remain ambiguous")
    func rejectsAmbiguousParallelRoutes() {
        let anchors = eastboundAnchors(count: 4, course: nil)
        let north = offsetCandidate(following: anchors, latitudeMeters: 22)
        let south = offsetCandidate(following: anchors, latitudeMeters: -22)

        #expect(engine.decide(anchors: anchors, candidates: [north, south]) == .ambiguous)
    }

    @Test("Travel mode inference covers path and transit bands", arguments: [
        (2, [PathTravelMode.walking, .cycling]),
        (6, [.cycling, .automobile]),
        (14, [.automobile, .transit]),
    ])
    func infersTravelModes(speed: Int, expected: [PathTravelMode]) {
        let anchors = eastboundAnchors(count: 3, speed: speed)
        #expect(engine.travelModes(for: anchors) == expected)
    }

    @Test("A matched route rasterizes a continuous corridor")
    func rasterizesMatchedPath() {
        let anchors = eastboundAnchors(count: 3)
        let path = anchors.map(\.coordinate)
        let exploration = ExplorationEngine()

        let corridor = exploration.process(matchedPath: path, unlockedAt: now)
        let point = exploration.process(
            sample: ExplorationLocationSample(
                coordinate: path[0],
                horizontalAccuracyMeters: 5,
                timestamp: now
            ),
            previous: nil,
            now: now
        )

        #expect(bitCount(corridor) > bitCount(point))
    }

    private func eastboundAnchors(
        count: Int,
        start: Date? = nil,
        course: Int? = 90,
        speed: Int = 6
    ) -> [PathAnchor] {
        let start = start ?? now
        return (0..<count).map { index in
            anchor(
                latitude: 52.52,
                longitude: 13.405 + Double(index) * 0.005,
                time: start.addingTimeInterval(Double(index) * 300),
                course: course,
                speed: speed
            )
        }
    }

    private func anchor(
        latitude: Double,
        longitude: Double,
        time: Date,
        course: Int? = 90,
        speed: Int = 6
    ) -> PathAnchor {
        PathAnchor(
            cell: CoverageCell.containing(
                GeoCoordinate(latitude: latitude, longitude: longitude),
                zoom: ExplorationConfiguration.streetPrecise.coverageZoom
            ),
            observedAt: time,
            accuracyBucketMeters: 10,
            speedBucketMetersPerSecond: speed,
            courseBucketDegrees: course
        )
    }

    private func candidate(following anchors: [PathAnchor]) -> PathRouteCandidate {
        let coordinates = anchors.map(\.coordinate)
        return PathRouteCandidate(
            coordinates: coordinates,
            distanceMeters: chainDistance(coordinates),
            expectedTravelTime: 600,
            mode: .automobile
        )
    }

    private func offsetCandidate(following anchors: [PathAnchor], latitudeMeters: Double) -> PathRouteCandidate {
        let latitudeOffset = latitudeMeters / 111_320
        let coordinates = anchors.map {
            GeoCoordinate(latitude: $0.coordinate.latitude + latitudeOffset, longitude: $0.coordinate.longitude)
        }
        return PathRouteCandidate(
            coordinates: coordinates,
            distanceMeters: chainDistance(coordinates),
            expectedTravelTime: 600,
            mode: .automobile
        )
    }

    private func chainDistance(_ coordinates: [GeoCoordinate]) -> Double {
        zip(coordinates, coordinates.dropFirst()).reduce(0) {
            $0 + $1.0.distance(to: $1.1)
        }
    }

    private func bitCount(_ delta: CoverageDelta) -> Int {
        delta.chunks.values.reduce(0) { $0 + $1.setBitCount }
    }
}
