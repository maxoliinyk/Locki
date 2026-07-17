//
//  PathMatchingModels.swift
//  Locki
//
//  Created by Max Oliinyk on 17.07.2026.
//

import Foundation

nonisolated enum PathAnchorSource: String, Codable, Hashable, Sendable {
    case significantChange
    case backgroundOneShot
    case legacy
}

nonisolated enum PathMotionKind: String, Codable, Hashable, Sendable {
    case stationary
    case walking
    case running
    case cycling
    case automotive
    case unknown

    init(_ activity: MotionActivityKind) {
        self = switch activity {
        case .stationary: .stationary
        case .walking: .walking
        case .running: .running
        case .cycling: .cycling
        case .automotive: .automotive
        case .unknown: .unknown
        }
    }

    var maximumAnchorGap: TimeInterval {
        switch self {
        case .walking, .running: 60 * 60
        case .cycling, .unknown, .stationary: 30 * 60
        case .automotive: 20 * 60
        }
    }
}

nonisolated struct PathAnchor: Hashable, Identifiable, Sendable {
    let id: UUID
    let cell: CoverageCell
    let observedAt: Date
    let accuracyBucketMeters: Int
    let speedBucketMetersPerSecond: Int?
    let courseBucketDegrees: Int?
    let source: PathAnchorSource
    let motionKind: PathMotionKind?
    let sessionID: UUID?

    init(
        id: UUID = UUID(),
        cell: CoverageCell,
        observedAt: Date,
        accuracyBucketMeters: Int,
        speedBucketMetersPerSecond: Int? = nil,
        courseBucketDegrees: Int? = nil,
        source: PathAnchorSource = .legacy,
        motionKind: PathMotionKind? = nil,
        sessionID: UUID? = nil
    ) {
        self.id = id
        self.cell = cell
        self.observedAt = observedAt
        self.accuracyBucketMeters = accuracyBucketMeters
        self.speedBucketMetersPerSecond = speedBucketMetersPerSecond
        self.courseBucketDegrees = courseBucketDegrees
        self.source = source
        self.motionKind = motionKind
        self.sessionID = sessionID
    }

    init(
        sample: ExplorationLocationSample,
        source: PathAnchorSource = .legacy,
        motionKind: PathMotionKind? = nil,
        sessionID: UUID? = nil,
        configuration: ExplorationConfiguration = .streetPrecise
    ) {
        id = UUID()
        cell = CoverageCell.containing(sample.coordinate, zoom: configuration.coverageZoom)
        observedAt = sample.timestamp
        accuracyBucketMeters = Int(ceil(sample.horizontalAccuracyMeters / 5)) * 5
        speedBucketMetersPerSecond = sample.speedMetersPerSecond.map { Int(ceil($0 / 2)) * 2 }
        courseBucketDegrees = sample.courseDegrees.map { course in
            Int((course / 15).rounded()) * 15 % 360
        }
        self.source = source
        self.motionKind = motionKind
        self.sessionID = sessionID
    }

    var coordinate: GeoCoordinate { cell.centerCoordinate }
}

nonisolated enum PathTravelMode: CaseIterable, Hashable, Sendable {
    case walking
    case cycling
    case automobile
    case transit
}

nonisolated struct PathRouteRequest: Hashable, Sendable {
    let source: GeoCoordinate
    let destination: GeoCoordinate
    let departureDate: Date
    let modes: [PathTravelMode]
}

nonisolated struct PathRouteCandidate: Hashable, Sendable {
    let coordinates: [GeoCoordinate]
    let distanceMeters: Double
    let expectedTravelTime: TimeInterval
    let mode: PathTravelMode
}

@MainActor
protocol PathRouteProviding: AnyObject {
    func routes(for request: PathRouteRequest) async throws -> [PathRouteCandidate]
}

nonisolated enum PathMatchDecision: Hashable, Sendable {
    case insufficientEvidence
    case matched(PathRouteCandidate)
    case ambiguous
    case temporarilyUnavailable
    case permanentlyRejected
}

nonisolated enum PathMatchFailureKind: String, Codable, Hashable, Sendable {
    case insufficientEvidence
    case ambiguous
    case routeUnavailable
    case cancelled
    case rejected
}

nonisolated struct PathMatchingConfiguration: Hashable, Sendable {
    let retentionInterval: TimeInterval
    let futureTimestampTolerance: TimeInterval
    let retryInterval: TimeInterval
    let maximumAttempts: Int
    let minimumAnchorCount: Int
    let maximumAnchorCount: Int
    let minimumSpanMeters: Double
    let maximumGap: TimeInterval
    let maximumSegmentDistanceMeters: Double
    let maximumSpeedMetersPerSecond: Double
    let maximumBacktrackMeters: Double
    let maximumMedianCrossTrackMeters: Double
    let maximumCrossTrackMeters: Double
    let equivalentCorridorMeters: Double
    let requiredScoreSeparation: Double
    let matchedPathRadiusMeters: Double
    let matchedPathSpacingMeters: Double
    let maximumAnchorAge: TimeInterval
    let maximumLegCount: Int
    let maximumLogicalRouteRequests: Int
    let candidateBeamWidth: Int
    let checkpointTurnDegrees: Double
    let stationaryBoundaryInterval: TimeInterval

    static let standard = PathMatchingConfiguration(
        retentionInterval: 6 * 60 * 60,
        futureTimestampTolerance: 10,
        retryInterval: 15 * 60,
        maximumAttempts: 6,
        minimumAnchorCount: 3,
        maximumAnchorCount: 8,
        minimumSpanMeters: 300,
        maximumGap: 20 * 60,
        maximumSegmentDistanceMeters: 25_000,
        maximumSpeedMetersPerSecond: 80,
        maximumBacktrackMeters: 50,
        maximumMedianCrossTrackMeters: 25,
        maximumCrossTrackMeters: 55,
        equivalentCorridorMeters: 20,
        requiredScoreSeparation: 1.25,
        matchedPathRadiusMeters: 10,
        matchedPathSpacingMeters: 8,
        maximumAnchorAge: 30 * 60,
        maximumLegCount: 4,
        maximumLogicalRouteRequests: 8,
        candidateBeamWidth: 8,
        checkpointTurnDegrees: 30,
        stationaryBoundaryInterval: 5 * 60
    )
}

nonisolated enum PathProcessingResult: Hashable, Sendable {
    case idle
    case matched
    case deferred(PathMatchFailureKind)
}
