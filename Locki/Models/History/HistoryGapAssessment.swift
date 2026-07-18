//
//  HistoryGapAssessment.swift
//  Locki
//
//  Created by Max Oliinyk on 18.07.2026.
//

import Foundation

nonisolated enum HistoryGapCapturePolicy {
    static let unavailableDelay: TimeInterval = 120

    static func persistsUnavailableGap(after duration: TimeInterval) -> Bool {
        duration >= unavailableDelay
    }
}

nonisolated struct HistoryGapEndpoint: Hashable, Sendable {
    let coordinate: GeoCoordinate
    let timestamp: Date
    let accuracyMeters: Int
    let speedMetersPerSecond: Double?
    let courseDegrees: Double?
}

nonisolated enum HistoryGapRouteIneligibility: Hashable, Sendable {
    case ongoing
    case notDiscontinuity
    case missingEndpoints
    case likelyNoMovement
    case tooFar
    case tooLong
    case implausibleSpeed
}

nonisolated struct HistoryGapAssessment: Hashable, Sendable {
    let start: HistoryGapEndpoint?
    let end: HistoryGapEndpoint?
    let directDistanceMeters: Double?
    let suggestedMode: HistoryGapTravelMode
    let routeIneligibility: HistoryGapRouteIneligibility?

    var canRequestRoutes: Bool { routeIneligibility == nil }
}

nonisolated struct HistoryGapSnapshot: Hashable, Identifiable, Sendable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date?
    let reason: HistoryGapReason
    let diagnosis: HistoryGapDiagnosis
    let resolution: HistoryGapResolution
    let resolvedAt: Date?
    let travelMode: HistoryGapTravelMode?
    let estimatedDistanceMeters: Double?
    let estimatedTravelTime: TimeInterval?
    let estimatedRoute: [GeoCoordinate]
    let assessment: HistoryGapAssessment

    var duration: TimeInterval? { endedAt.map { max($0.timeIntervalSince(startedAt), 0) } }
}

nonisolated struct GapRouteCandidate: Hashable, Sendable {
    let coordinates: [GeoCoordinate]
    let distanceMeters: Double
    let expectedTravelTime: TimeInterval
    let mode: HistoryGapTravelMode
}

nonisolated struct GapRouteSuggestion: Hashable, Identifiable, Sendable {
    let id: UUID
    let coordinates: [GeoCoordinate]
    let distanceMeters: Double
    let expectedTravelTime: TimeInterval
    let mode: HistoryGapTravelMode
    let isRecommended: Bool
}

nonisolated struct HistoryGapAssessmentEngine: Sendable {
    static let minimumRouteDistanceMeters = 100.0
    static let maximumRouteDistanceMeters = 100_000.0
    static let maximumRouteDuration: TimeInterval = 2 * 60 * 60
    static let maximumImpliedSpeedMetersPerSecond = 80.0

    func assess(
        reason: HistoryGapReason,
        startedAt: Date,
        endedAt: Date?,
        start: HistoryGapEndpoint?,
        end: HistoryGapEndpoint?,
        surroundingModes: [MovementMode]
    ) -> HistoryGapAssessment {
        let mode = suggestedMode(surroundingModes: surroundingModes, start: start, end: end)
        guard reason == .discontinuity else {
            return HistoryGapAssessment(
                start: start,
                end: end,
                directDistanceMeters: nil,
                suggestedMode: mode,
                routeIneligibility: .notDiscontinuity
            )
        }
        guard let endedAt else {
            return HistoryGapAssessment(
                start: start,
                end: end,
                directDistanceMeters: nil,
                suggestedMode: mode,
                routeIneligibility: .ongoing
            )
        }
        guard let start, let end else {
            return HistoryGapAssessment(
                start: start,
                end: end,
                directDistanceMeters: nil,
                suggestedMode: mode,
                routeIneligibility: .missingEndpoints
            )
        }
        let distance = start.coordinate.distance(to: end.coordinate)
        let duration = endedAt.timeIntervalSince(startedAt)
        let ineligibility: HistoryGapRouteIneligibility? = if distance < Self.minimumRouteDistanceMeters {
            .likelyNoMovement
        } else if distance > Self.maximumRouteDistanceMeters {
            .tooFar
        } else if duration > Self.maximumRouteDuration {
            .tooLong
        } else if duration <= 0 || distance / duration > Self.maximumImpliedSpeedMetersPerSecond {
            .implausibleSpeed
        } else {
            nil
        }
        return HistoryGapAssessment(
            start: start,
            end: end,
            directDistanceMeters: distance,
            suggestedMode: mode,
            routeIneligibility: ineligibility
        )
    }

    func rankedSuggestions(
        _ candidates: [GapRouteCandidate],
        gapDuration: TimeInterval,
        directDistanceMeters: Double
    ) -> [GapRouteSuggestion] {
        let scored = candidates.compactMap { candidate -> (GapRouteCandidate, Double)? in
            guard candidate.coordinates.count >= 2,
                  candidate.distanceMeters.isFinite,
                  candidate.distanceMeters >= directDistanceMeters * 0.95,
                  candidate.distanceMeters <= Self.maximumRouteDistanceMeters,
                  candidate.expectedTravelTime.isFinite,
                  candidate.expectedTravelTime >= 0 else { return nil }
            let detour = candidate.distanceMeters / max(directDistanceMeters, 1)
            guard detour <= 2.5 else { return nil }
            let timeRatio = max(candidate.expectedTravelTime, 1) / max(gapDuration, 1)
            let score = max(detour - 1, 0) * 20 + abs(log(timeRatio)) * 8
            return (candidate, score)
        }.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            return lhs.0.distanceMeters < rhs.0.distanceMeters
        }
        let recommended: Int? = if scored.count == 1 {
            0
        } else if let first = scored.first,
                  scored[1].1 >= max(first.1 * 1.15, first.1 + 0.5) {
            0
        } else {
            nil
        }
        return scored.enumerated().map { index, value in
            GapRouteSuggestion(
                id: UUID(),
                coordinates: value.0.coordinates,
                distanceMeters: value.0.distanceMeters,
                expectedTravelTime: value.0.expectedTravelTime,
                mode: value.0.mode,
                isRecommended: index == recommended
            )
        }
    }

    private func suggestedMode(
        surroundingModes: [MovementMode],
        start: HistoryGapEndpoint?,
        end: HistoryGapEndpoint?
    ) -> HistoryGapTravelMode {
        if surroundingModes.contains(.motorized) { return .automobile }
        if surroundingModes.contains(.cycling) { return .cycling }
        if surroundingModes.contains(.walking) { return .walking }
        let speeds = [start?.speedMetersPerSecond, end?.speedMetersPerSecond].compactMap { $0 }
        let peak = speeds.max() ?? 0
        if peak > 8 { return .automobile }
        if peak > 2.5 { return .cycling }
        return .walking
    }
}

nonisolated extension HistoryGapReason {
    var defaultDiagnosis: HistoryGapDiagnosis {
        switch self {
        case .authorization: .permissionUnavailable
        case .reducedAccuracy: .preciseLocationUnavailable
        case .discontinuity: .unknownDiscontinuity
        case .disabled: .historyDisabled
        case .persistence: .saveFailed
        case .unavailable: .locationTemporarilyUnavailable
        }
    }
}

nonisolated extension HistoryGapEndpoint {
    init(_ point: HistoryPoint) {
        self.init(
            coordinate: point.coordinate,
            timestamp: point.timestamp,
            accuracyMeters: Int(point.accuracyBucketMeters),
            speedMetersPerSecond: point.speedMetersPerSecond,
            courseDegrees: point.courseDegrees
        )
    }
}
