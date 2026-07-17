//
//  ExplorationEngine.swift
//  Locki
//
//  Created by Max Oliinyk on 06.05.2026.
//

import Foundation

nonisolated struct ExplorationEngine: Sendable {
    let configuration: ExplorationConfiguration

    init(configuration: ExplorationConfiguration = .streetPrecise) {
        self.configuration = configuration
    }

    func acceptedSample(_ sample: ExplorationLocationSample, now: Date = .now) -> Bool {
        guard sample.hasPreciseAccuracy,
              sample.coordinate.isValid,
              sample.horizontalAccuracyMeters.isFinite,
              sample.horizontalAccuracyMeters >= 0,
              sample.horizontalAccuracyMeters <= configuration.maximumHorizontalAccuracyMeters else {
            return false
        }

        if let speed = sample.speedMetersPerSecond,
           (!speed.isFinite || speed < 0 || speed > configuration.maximumSpeedMetersPerSecond) {
            return false
        }

        let age = now.timeIntervalSince(sample.timestamp)
        return age >= -configuration.futureTimestampTolerance
            && age <= configuration.maximumSampleAge
    }

    func revealRadius(for sample: ExplorationLocationSample) -> Double {
        min(
            max(
                configuration.revealRadiusBaseMeters
                    - configuration.accuracyRadiusPenalty * sample.horizontalAccuracyMeters,
                configuration.minimumRevealRadiusMeters
            ),
            configuration.maximumRevealRadiusMeters
        )
    }

    func process(
        sample: ExplorationLocationSample,
        previous: ExplorationLocationSample?,
        now: Date = .now
    ) -> CoverageDelta {
        guard acceptedSample(sample, now: now) else {
            return CoverageDelta(unlockedAt: sample.timestamp)
        }

        var delta = CoverageDelta(unlockedAt: sample.timestamp)
        let radius = revealRadius(for: sample)
        rasterizeDisk(center: sample.coordinate, radiusMeters: radius, into: &delta)

        guard let previous,
              acceptedSample(previous, now: now),
              shouldConnect(previous, to: sample) else {
            return delta
        }

        let distance = previous.coordinate.distance(to: sample.coordinate)
        let steps = max(Int(ceil(distance / configuration.interpolationSpacingMeters)), 1)
        for step in 1..<steps {
            let fraction = Double(step) / Double(steps)
            let coordinate = previous.coordinate.interpolated(to: sample.coordinate, fraction: fraction)
            let interpolatedAccuracy = previous.horizontalAccuracyMeters
                + (sample.horizontalAccuracyMeters - previous.horizontalAccuracyMeters) * fraction
            let interpolatedSample = ExplorationLocationSample(
                coordinate: coordinate,
                horizontalAccuracyMeters: interpolatedAccuracy,
                speedMetersPerSecond: sample.speedMetersPerSecond,
                timestamp: sample.timestamp,
                hasPreciseAccuracy: true
            )
            rasterizeDisk(center: coordinate, radiusMeters: revealRadius(for: interpolatedSample), into: &delta)
        }

        return delta
    }

    func process(
        matchedPath coordinates: [GeoCoordinate],
        unlockedAt: Date,
        radiusMeters: Double = PathMatchingConfiguration.standard.matchedPathRadiusMeters,
        spacingMeters: Double = PathMatchingConfiguration.standard.matchedPathSpacingMeters
    ) -> CoverageDelta {
        var delta = CoverageDelta(unlockedAt: unlockedAt)
        guard let first = coordinates.first, first.isValid, radiusMeters > 0, spacingMeters > 0 else {
            return delta
        }

        rasterizeDisk(center: first, radiusMeters: radiusMeters, into: &delta)
        for (start, end) in zip(coordinates, coordinates.dropFirst()) where start.isValid && end.isValid {
            let distance = start.distance(to: end)
            guard distance.isFinite, distance <= 100_000 else { continue }
            let steps = max(Int(ceil(distance / spacingMeters)), 1)
            for step in 1...steps {
                let coordinate = start.interpolated(to: end, fraction: Double(step) / Double(steps))
                rasterizeDisk(center: coordinate, radiusMeters: radiusMeters, into: &delta)
            }
        }
        return delta
    }

    private func shouldConnect(_ previous: ExplorationLocationSample, to sample: ExplorationLocationSample) -> Bool {
        let timeDelta = sample.timestamp.timeIntervalSince(previous.timestamp)
        guard timeDelta > 0, timeDelta <= configuration.maximumConnectionAge else { return false }

        let distance = previous.coordinate.distance(to: sample.coordinate)
        let inferredSpeed = distance / timeDelta
        guard inferredSpeed <= configuration.maximumSpeedMetersPerSecond else { return false }

        let reportedSpeed = max(previous.speedMetersPerSecond ?? 0, sample.speedMetersPerSecond ?? 0)
        return reportedSpeed == 0 || inferredSpeed <= max(20, reportedSpeed * 2 + 10)
    }

    private func rasterizeDisk(center: GeoCoordinate, radiusMeters: Double, into delta: inout CoverageDelta) {
        let containing = CoverageCell.containing(center, zoom: configuration.coverageZoom)
        let metersPerCell = max(
            cos(center.latitude * .pi / 180) * 40_075_016.686 / Double(1 << configuration.coverageZoom),
            1
        )
        let searchRadius = Int(ceil(radiusMeters / metersPerCell)) + 1
        let tileCount = 1 << configuration.coverageZoom

        for yOffset in -searchRadius...searchRadius {
            let y = containing.y + yOffset
            guard (0..<tileCount).contains(y) else { continue }

            for xOffset in -searchRadius...searchRadius {
                var x = containing.x + xOffset
                if x < 0 { x += tileCount }
                if x >= tileCount { x -= tileCount }
                let cell = CoverageCell(x: x, y: y, zoom: configuration.coverageZoom)
                let cellAllowance = metersPerCell * 0.72
                guard center.distance(to: cell.centerCoordinate) <= radiusMeters + cellAllowance else { continue }
                delta.insert(cell, configuration: configuration)
            }
        }
    }
}
