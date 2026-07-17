//
//  PathMatchingEngine.swift
//  Locki
//
//  Created by Max Oliinyk on 17.07.2026.
//

import Foundation

nonisolated struct PathMatchingEngine: Sendable {
    let configuration: PathMatchingConfiguration

    init(configuration: PathMatchingConfiguration = .standard) {
        self.configuration = configuration
    }

    func matchingWindow(from anchors: [PathAnchor], now: Date = .now) -> [PathAnchor] {
        let valid = anchors
            .filter {
                let age = now.timeIntervalSince($0.observedAt)
                return age >= -configuration.futureTimestampTolerance && age <= configuration.retentionInterval
            }
            .sorted { $0.observedAt < $1.observedAt }
        guard let last = valid.last else { return [] }

        var suffix = [last]
        for anchor in valid.dropLast().reversed() {
            guard let next = suffix.first else { break }
            if let anchorSession = anchor.sessionID,
               let nextSession = next.sessionID,
               anchorSession != nextSession {
                break
            }
            let duration = next.observedAt.timeIntervalSince(anchor.observedAt)
            let distance = anchor.coordinate.distance(to: next.coordinate)
            let maximumGap = min(
                anchor.motionKind?.maximumAnchorGap ?? PathMotionKind.unknown.maximumAnchorGap,
                next.motionKind?.maximumAnchorGap ?? PathMotionKind.unknown.maximumAnchorGap
            )
            guard duration > 0,
                  duration <= maximumGap,
                  distance <= configuration.maximumSegmentDistanceMeters,
                  distance / duration <= configuration.maximumSpeedMetersPerSecond else {
                break
            }
            suffix.insert(anchor, at: 0)
            if suffix.count == configuration.maximumAnchorCount { break }
        }

        guard suffix.count >= configuration.minimumAnchorCount,
              chainDistance(suffix) >= configuration.minimumSpanMeters else {
            return []
        }
        return suffix
    }

    func travelModes(for anchors: [PathAnchor]) -> [PathTravelMode] {
        guard anchors.count >= 2 else { return [.walking, .cycling] }
        let motions = anchors.compactMap(\.motionKind)
        if motions.contains(.automotive) { return [.automobile, .transit] }
        if motions.contains(.cycling) { return [.cycling, .automobile] }
        if motions.contains(where: { $0 == .walking || $0 == .running }) {
            return [.walking, .cycling]
        }
        let reported = anchors.compactMap(\.speedBucketMetersPerSecond).map(Double.init).sorted()
        let reportedMedian = reported.isEmpty ? 0 : reported[reported.count / 2]
        let elapsed = max((anchors.last?.observedAt.timeIntervalSince(anchors.first?.observedAt ?? .distantPast) ?? 0), 1)
        let implied = chainDistance(anchors) / elapsed
        let evidence = max(reportedMedian, implied)

        if evidence <= 2.5 { return [.walking, .cycling] }
        if evidence < 8 { return [.cycling, .automobile] }
        return [.automobile, .transit]
    }

    func routeRequest(for anchors: [PathAnchor]) -> PathRouteRequest? {
        guard let first = anchors.first, let last = anchors.last, first.id != last.id else { return nil }
        return PathRouteRequest(
            source: first.coordinate,
            destination: last.coordinate,
            departureDate: first.observedAt,
            modes: travelModes(for: anchors)
        )
    }

    func decide(anchors: [PathAnchor], candidates: [PathRouteCandidate]) -> PathMatchDecision {
        guard anchors.count >= configuration.minimumAnchorCount else { return .insufficientEvidence }
        let scored = candidates.compactMap { candidate -> ScoredCandidate? in
            guard let score = score(candidate: candidate, anchors: anchors) else { return nil }
            return ScoredCandidate(candidate: candidate, score: score)
        }.sorted { $0.score < $1.score }

        guard let best = scored.first else { return .ambiguous }
        if scored.count == 1 {
            let projections = projections(of: anchors, onto: best.candidate.coordinates)
            let hasStrongHeadingEvidence = headingDeviations(anchors: anchors, projections: projections).count >= 2
            let maximumDistance = projections.map(\.distanceMeters).max() ?? .infinity
            guard anchors.count >= 4 || (hasStrongHeadingEvidence && maximumDistance <= 30) else {
                return .insufficientEvidence
            }
            return .matched(best.candidate)
        }

        let credible = scored.filter { $0.score < best.score * configuration.requiredScoreSeparation }
        if credible.dropFirst().allSatisfy({
            corridorsAreEquivalent(best.candidate.coordinates, $0.candidate.coordinates)
        }) {
            return .matched(best.candidate)
        }
        let runnerUp = scored.first {
            !corridorsAreEquivalent(best.candidate.coordinates, $0.candidate.coordinates)
        }
        guard let runnerUp else { return .matched(best.candidate) }
        guard runnerUp.score >= best.score * configuration.requiredScoreSeparation else {
            return .ambiguous
        }
        return .matched(best.candidate)
    }

    func fallbackWindows(
        for anchors: [PathAnchor],
        primaryCandidates: [PathRouteCandidate] = []
    ) -> [[PathAnchor]] {
        guard anchors.count >= 4 else { return [] }
        let modesPerRequest = max(travelModes(for: anchors).count, 1)
        let remainingRequestBudget = max(configuration.maximumLogicalRouteRequests - modesPerRequest, 0)
        let maximumLegs = min(
            configuration.maximumLegCount,
            remainingRequestBudget / modesPerRequest,
            anchors.count - 1
        )
        guard maximumLegs >= 2 else { return [] }

        var indexes: Set<Int> = [0, anchors.count - 1]
        let rankedIndexes = (1..<(anchors.count - 1)).map { index -> (index: Int, priority: Double) in
            let previous = anchors[index - 1]
            let current = anchors[index]
            var priority = primaryCandidates.compactMap {
                project(current.coordinate, onto: $0.coordinates)?.distanceMeters
            }.min() ?? 0
            if previous.motionKind != nil, current.motionKind != nil,
               previous.motionKind != current.motionKind {
                priority += 10_000
            }
            if let previousCourse = previous.courseBucketDegrees,
               let currentCourse = current.courseBucketDegrees,
               angularDifference(Double(previousCourse), Double(currentCourse))
                >= configuration.checkpointTurnDegrees {
                priority += 5_000
            }
            return (index, priority)
        }.sorted { $0.priority > $1.priority }
        for item in rankedIndexes where indexes.count < maximumLegs + 1 {
            guard item.priority > 0 else { break }
            indexes.insert(item.index)
        }
        while indexes.count < maximumLegs + 1 {
            let sorted = indexes.sorted()
            guard let widest = zip(sorted, sorted.dropFirst()).max(by: {
                ($0.1 - $0.0) < ($1.1 - $1.0)
            }), widest.1 - widest.0 > 1 else { break }
            indexes.insert((widest.0 + widest.1) / 2)
        }
        let sorted = indexes.sorted()
        return zip(sorted, sorted.dropFirst()).map { start, end in
            Array(anchors[start...end])
        }
    }

    func stitchedCandidates(from legs: [[PathRouteCandidate]]) -> [PathRouteCandidate] {
        guard let first = legs.first, !first.isEmpty else { return [] }
        var beam = Array(first.prefix(configuration.candidateBeamWidth))
        for alternatives in legs.dropFirst() {
            var combined: [PathRouteCandidate] = []
            for prefix in beam {
                for suffix in alternatives.prefix(configuration.candidateBeamWidth) {
                    guard let prefixEnd = prefix.coordinates.last,
                          let suffixStart = suffix.coordinates.first,
                          prefix.mode == suffix.mode,
                          prefixEnd.distance(to: suffixStart) <= configuration.maximumCrossTrackMeters else {
                        continue
                    }
                    combined.append(
                        PathRouteCandidate(
                            coordinates: prefix.coordinates + Array(suffix.coordinates.dropFirst()),
                            distanceMeters: prefix.distanceMeters + suffix.distanceMeters,
                            expectedTravelTime: prefix.expectedTravelTime + suffix.expectedTravelTime,
                            mode: suffix.mode
                        )
                    )
                }
            }
            beam = Array(
                combined.sorted {
                    if $0.distanceMeters != $1.distanceMeters { return $0.distanceMeters < $1.distanceMeters }
                    return $0.expectedTravelTime < $1.expectedTravelTime
                }.prefix(configuration.candidateBeamWidth)
            )
            if beam.isEmpty { break }
        }
        return beam
    }

    private func score(candidate: PathRouteCandidate, anchors: [PathAnchor]) -> Double? {
        guard candidate.coordinates.count >= 2,
              candidate.distanceMeters.isFinite,
              candidate.distanceMeters > 0,
              candidate.expectedTravelTime.isFinite,
              candidate.expectedTravelTime >= 0 else { return nil }
        let projections = projections(of: anchors, onto: candidate.coordinates)
        guard projections.count == anchors.count else { return nil }

        let distances = projections.map(\.distanceMeters).sorted()
        let medianDistance = distances[distances.count / 2]
        guard medianDistance <= configuration.maximumMedianCrossTrackMeters else { return nil }
        for (anchor, projection) in zip(anchors, projections) {
            let allowed = min(
                configuration.maximumCrossTrackMeters,
                Double(anchor.accuracyBucketMeters + 20)
            )
            guard projection.distanceMeters <= allowed else { return nil }
        }

        for pair in zip(projections, projections.dropFirst()) {
            guard pair.1.progressMeters + configuration.maximumBacktrackMeters >= pair.0.progressMeters else {
                return nil
            }
        }

        let anchorDistance = chainDistance(anchors)
        let maximumRouteDistance = max(anchorDistance * 1.6, anchorDistance + 250)
        guard candidate.distanceMeters <= maximumRouteDistance else { return nil }

        let headings = headingDeviations(anchors: anchors, projections: projections).sorted()
        if headings.count >= 2, headings[headings.count / 2] > 45 { return nil }

        let weightedDistance = zip(anchors, projections).reduce(0.0) { partial, pair in
            partial + pair.1.distanceMeters / Double(max(pair.0.accuracyBucketMeters, 5))
        } / Double(anchors.count) * 10
        let detourPenalty = max(candidate.distanceMeters / max(anchorDistance, 1) - 1, 0) * 20
        let headingPenalty = headings.isEmpty ? 0 : headings[headings.count / 2] * 0.2
        let observedDuration = max(
            anchors.last?.observedAt.timeIntervalSince(anchors.first?.observedAt ?? .distantPast) ?? 0,
            1
        )
        let timePenalty: Double = if candidate.expectedTravelTime > 0 {
            abs(log(candidate.expectedTravelTime / observedDuration)) * 8
        } else {
            0
        }
        let motionPenalty = motionPenalty(candidate.mode, anchors: anchors)
        return max(weightedDistance + detourPenalty + headingPenalty + timePenalty + motionPenalty, 0.001)
    }

    private func motionPenalty(_ mode: PathTravelMode, anchors: [PathAnchor]) -> Double {
        let motions = Set(anchors.compactMap(\.motionKind))
        guard !motions.isEmpty else { return 0 }
        let compatible = switch mode {
        case .walking: motions.contains(.walking) || motions.contains(.running)
        case .cycling: motions.contains(.cycling) || motions.contains(.walking) || motions.contains(.running)
        case .automobile, .transit: motions.contains(.automotive)
        }
        return compatible ? 0 : 25
    }

    private func projections(of anchors: [PathAnchor], onto path: [GeoCoordinate]) -> [Projection] {
        anchors.compactMap { project($0.coordinate, onto: path) }
    }

    private func project(_ point: GeoCoordinate, onto path: [GeoCoordinate]) -> Projection? {
        guard path.count >= 2 else { return nil }
        var best: Projection?
        var progress = 0.0

        for (start, end) in zip(path, path.dropFirst()) {
            let segmentLength = start.distance(to: end)
            guard segmentLength > 0 else { continue }
            let vector = localVector(from: start, to: end)
            let pointVector = localVector(from: start, to: point)
            let denominator = vector.x * vector.x + vector.y * vector.y
            let fraction = min(max((pointVector.x * vector.x + pointVector.y * vector.y) / denominator, 0), 1)
            let dx = pointVector.x - vector.x * fraction
            let dy = pointVector.y - vector.y * fraction
            let distance = hypot(dx, dy)
            let projection = Projection(
                distanceMeters: distance,
                progressMeters: progress + segmentLength * fraction,
                headingDegrees: bearing(from: start, to: end)
            )
            if best == nil || distance < best?.distanceMeters ?? .infinity { best = projection }
            progress += segmentLength
        }
        return best
    }

    private func headingDeviations(anchors: [PathAnchor], projections: [Projection]) -> [Double] {
        zip(anchors, projections).compactMap { anchor, projection in
            guard let course = anchor.courseBucketDegrees else { return nil }
            let delta = abs(Double(course) - projection.headingDegrees).truncatingRemainder(dividingBy: 360)
            return min(delta, 360 - delta)
        }
    }

    private func corridorsAreEquivalent(_ first: [GeoCoordinate], _ second: [GeoCoordinate]) -> Bool {
        guard first.count >= 2, second.count >= 2 else { return false }
        return maximumSampledDistance(from: first, to: second) <= configuration.equivalentCorridorMeters
            && maximumSampledDistance(from: second, to: first) <= configuration.equivalentCorridorMeters
    }

    private func maximumSampledDistance(from source: [GeoCoordinate], to target: [GeoCoordinate]) -> Double {
        let stride = max(source.count / 100, 1)
        return source.enumerated().compactMap { index, coordinate in
            guard index % stride == 0 || index == source.count - 1 else { return nil }
            return project(coordinate, onto: target)?.distanceMeters
        }.max() ?? .infinity
    }

    private func chainDistance(_ anchors: [PathAnchor]) -> Double {
        zip(anchors, anchors.dropFirst()).reduce(0) { partial, pair in
            partial + pair.0.coordinate.distance(to: pair.1.coordinate)
        }
    }

    private func localVector(from start: GeoCoordinate, to end: GeoCoordinate) -> (x: Double, y: Double) {
        let earthRadius = 6_371_000.0
        let latitudeDelta = (end.latitude - start.latitude) * .pi / 180
        var longitudeDelta = end.longitude - start.longitude
        if longitudeDelta > 180 { longitudeDelta -= 360 }
        if longitudeDelta < -180 { longitudeDelta += 360 }
        let meanLatitude = (start.latitude + end.latitude) * .pi / 360
        return (
            longitudeDelta * .pi / 180 * cos(meanLatitude) * earthRadius,
            latitudeDelta * earthRadius
        )
    }

    private func bearing(from start: GeoCoordinate, to end: GeoCoordinate) -> Double {
        let vector = localVector(from: start, to: end)
        let degrees = atan2(vector.x, vector.y) * 180 / .pi
        return degrees >= 0 ? degrees : degrees + 360
    }

    private func angularDifference(_ first: Double, _ second: Double) -> Double {
        let delta = abs(first - second).truncatingRemainder(dividingBy: 360)
        return min(delta, 360 - delta)
    }
}

private nonisolated struct Projection: Sendable {
    let distanceMeters: Double
    let progressMeters: Double
    let headingDegrees: Double
}

private nonisolated struct ScoredCandidate: Sendable {
    let candidate: PathRouteCandidate
    let score: Double
}
