//
//  SparsePathAnchorPolicy.swift
//  Locki
//
//  Created by Max Oliinyk on 17.07.2026.
//

import Foundation

nonisolated struct SparsePathAnchorPolicy: Sendable {
    let explorationConfiguration: ExplorationConfiguration
    let matchingConfiguration: PathMatchingConfiguration

    init(
        explorationConfiguration: ExplorationConfiguration = .streetPrecise,
        matchingConfiguration: PathMatchingConfiguration = .standard
    ) {
        self.explorationConfiguration = explorationConfiguration
        self.matchingConfiguration = matchingConfiguration
    }

    func accepts(_ sample: ExplorationLocationSample, now: Date = .now) -> Bool {
        guard sample.hasPreciseAccuracy,
              sample.coordinate.isValid,
              sample.horizontalAccuracyMeters.isFinite,
              (0...explorationConfiguration.maximumHorizontalAccuracyMeters)
                .contains(sample.horizontalAccuracyMeters) else {
            return false
        }
        if let speed = sample.speedMetersPerSecond,
           (!speed.isFinite || !(0...matchingConfiguration.maximumSpeedMetersPerSecond).contains(speed)) {
            return false
        }
        let age = now.timeIntervalSince(sample.timestamp)
        return age >= -matchingConfiguration.futureTimestampTolerance
            && age <= matchingConfiguration.maximumAnchorAge
    }

    func canContinue(
        from previous: ExplorationLocationSample,
        previousMotion: PathMotionKind?,
        to sample: ExplorationLocationSample,
        motion: PathMotionKind?
    ) -> Bool {
        let duration = sample.timestamp.timeIntervalSince(previous.timestamp)
        let maximumGap = min(
            previousMotion?.maximumAnchorGap ?? PathMotionKind.unknown.maximumAnchorGap,
            motion?.maximumAnchorGap ?? PathMotionKind.unknown.maximumAnchorGap
        )
        guard duration > 0, duration <= maximumGap else { return false }
        let distance = previous.coordinate.distance(to: sample.coordinate)
        return distance.isFinite
            && distance <= matchingConfiguration.maximumSegmentDistanceMeters
            && distance / duration <= matchingConfiguration.maximumSpeedMetersPerSecond
    }
}
