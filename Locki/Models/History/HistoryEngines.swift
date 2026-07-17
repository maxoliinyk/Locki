//
//  HistoryEngines.swift
//  Locki
//
//  Created by Max Oliinyk on 17.07.2026.
//

import Foundation

nonisolated struct HistorySampleFilter: Sendable {
    let configuration: HistoryConfiguration

    init(configuration: HistoryConfiguration = .standard) {
        self.configuration = configuration
    }

    func accepts(_ sample: HistoryLocationSample, now: Date = .now) -> Bool {
        guard sample.hasPreciseAccuracy,
              sample.coordinate.isValid,
              sample.horizontalAccuracyMeters.isFinite,
              (0...configuration.maximumHorizontalAccuracyMeters).contains(sample.horizontalAccuracyMeters),
              now.timeIntervalSince(sample.timestamp) >= -configuration.futureTimestampTolerance,
              now.timeIntervalSince(sample.timestamp) <= configuration.maximumSampleAge else {
            return false
        }

        if let speed = sample.speedMetersPerSecond,
           (!speed.isFinite || !(0...configuration.maximumSpeedMetersPerSecond).contains(speed)) {
            return false
        }
        if let course = sample.courseDegrees, (!course.isFinite || !(0..<360).contains(course)) {
            return false
        }
        return true
    }

    func formsPlausibleSegment(from previous: HistoryPoint, to current: HistoryPoint) -> Bool {
        let duration = current.timestamp.timeIntervalSince(previous.timestamp)
        guard duration > 0, duration <= configuration.tripGapInterval else { return false }
        let distance = previous.coordinate.distance(to: current.coordinate)
        let inferredSpeed = distance / duration
        guard inferredSpeed.isFinite, inferredSpeed <= configuration.maximumSpeedMetersPerSecond else {
            return false
        }
        let reported = max(previous.speedMetersPerSecond ?? 0, current.speedMetersPerSecond ?? 0)
        return reported == 0 || inferredSpeed <= max(20, reported * 2 + 10)
    }
}

nonisolated struct TrajectoryReducer: Sendable {
    let configuration: HistoryConfiguration

    init(configuration: HistoryConfiguration = .standard) {
        self.configuration = configuration
    }

    func shouldRetain(_ sample: HistoryLocationSample, after previous: HistoryPoint?) -> Bool {
        guard let previous else { return true }
        let current = HistoryPoint(sample: sample)
        let duration = current.timestamp.timeIntervalSince(previous.timestamp)
        guard duration > 0 else { return false }
        if duration >= configuration.maximumRetainedInterval { return true }
        if previous.coordinate.distance(to: current.coordinate) >= configuration.minimumRetainedDistanceMeters {
            return true
        }
        if speedClass(previous.speedMetersPerSecond) != speedClass(current.speedMetersPerSecond) {
            return true
        }
        guard let oldCourse = previous.courseDegrees, let newCourse = current.courseDegrees else {
            return false
        }
        let rawDelta = abs(oldCourse - newCourse).truncatingRemainder(dividingBy: 360)
        return min(rawDelta, 360 - rawDelta) >= configuration.minimumHeadingChangeDegrees
    }

    func movementMode(for speeds: [Double]) -> (mode: MovementMode, confidence: Double) {
        let valid = speeds.filter { $0.isFinite && $0 >= 0 }.sorted()
        guard valid.count >= 3 else { return (.unknown, 0) }
        let median = valid[valid.count / 2]
        let percentile95 = valid[min(Int(Double(valid.count - 1) * 0.95), valid.count - 1)]
        if percentile95 <= 3.5 {
            return (.walking, min(Double(valid.count) / 12, 1))
        }
        if median >= 2.2, percentile95 < 15 {
            return (.cycling, min(Double(valid.count) / 16, 0.9))
        }
        if median > 8 || percentile95 >= 15 {
            return (.motorized, min(Double(valid.count) / 16, 0.9))
        }
        return (.unknown, 0.3)
    }

    func peakSpeed(for speeds: [Double]) -> Double {
        let values = speeds.filter { $0.isFinite && $0 >= 0 }.sorted()
        guard !values.isEmpty else { return 0 }
        return values[min(Int(Double(values.count - 1) * 0.95), values.count - 1)]
    }

    private func speedClass(_ speed: Double?) -> MovementMode {
        guard let speed else { return .unknown }
        if speed <= 3.5 { return .walking }
        if speed < 15 { return .cycling }
        return .motorized
    }
}

nonisolated struct VisitInferenceEngine: Sendable {
    let configuration: HistoryConfiguration

    init(configuration: HistoryConfiguration = .standard) {
        self.configuration = configuration
    }

    func radius(forAccuracy accuracy: Double) -> Double {
        min(max(configuration.baseVisitRadiusMeters, accuracy * 2), configuration.maximumVisitRadiusMeters)
    }

    func isInsideCandidate(
        sample: HistoryLocationSample,
        center: GeoCoordinate,
        candidateAccuracy: Double
    ) -> Bool {
        sample.coordinate.distance(to: center) <= radius(forAccuracy: max(candidateAccuracy, sample.horizontalAccuracyMeters))
    }

    func qualifies(startedAt: Date, current: Date) -> Bool {
        current.timeIntervalSince(startedAt) >= configuration.minimumVisitDuration
    }
}

nonisolated struct RouteSimilarityEngine: Sendable {
    func matches(_ first: [HistoryPoint], _ second: [HistoryPoint]) -> Bool {
        guard first.count >= 2, second.count >= 2 else { return false }
        let firstLength = length(first)
        let secondLength = length(second)
        guard firstLength > 0, secondLength > 0 else { return false }
        let ratio = firstLength / secondLength
        guard (0.7...1.3).contains(ratio) else { return false }

        let forward = sampledDistances(from: first, to: second).sorted()
        let reverse = sampledDistances(from: first, to: Array(second.reversed())).sorted()
        let distances = (median(forward) <= median(reverse) ? forward : reverse)
        guard !distances.isEmpty else { return false }
        let p90 = distances[min(Int(Double(distances.count - 1) * 0.9), distances.count - 1)]
        return median(distances) <= 40 && p90 <= 100
    }

    private func length(_ points: [HistoryPoint]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { result, pair in
            result + pair.0.coordinate.distance(to: pair.1.coordinate)
        }
    }

    private func sampledDistances(from source: [HistoryPoint], to target: [HistoryPoint]) -> [Double] {
        let stride = max(source.count / 50, 1)
        return source.enumerated().compactMap { index, point in
            guard index % stride == 0 || index == source.count - 1 else { return nil }
            return target.map { point.coordinate.distance(to: $0.coordinate) }.min()
        }
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return .infinity }
        return values[values.count / 2]
    }
}

nonisolated struct FavoriteRanker: Sendable {
    func places(_ places: [HistoryPlaceRecordSnapshot], limit: Int = 5) -> [HistoryPlaceRecordSnapshot] {
        places
            .filter { !$0.isExcluded && $0.isFavorite }
            .sorted {
                if $0.isFavorite != $1.isFavorite { return $0.isFavorite }
                if $0.totalDuration != $1.totalDuration { return $0.totalDuration > $1.totalDuration }
                if $0.visitCount != $1.visitCount { return $0.visitCount > $1.visitCount }
                if $0.distinctDayCount != $1.distinctDayCount { return $0.distinctDayCount > $1.distinctDayCount }
                return ($0.lastVisitAt ?? .distantPast) > ($1.lastVisitAt ?? .distantPast)
            }
            .prefix(limit)
            .map { $0 }
    }
}

nonisolated struct FrequentPlaceRanker: Sendable {
    static let minimumVisitCount = 3
    static let minimumDistinctDayCount = 2
    static let minimumDuration: TimeInterval = 30 * 60

    func qualifies(_ place: HistoryPlaceRecordSnapshot) -> Bool {
        !place.isExcluded
            && place.visitCount >= Self.minimumVisitCount
            && place.distinctDayCount >= Self.minimumDistinctDayCount
            && place.totalDuration >= Self.minimumDuration
    }

    func places(_ places: [HistoryPlaceRecordSnapshot]) -> [HistoryPlaceRecordSnapshot] {
        places.filter(qualifies).sorted {
            if $0.totalDuration != $1.totalDuration { return $0.totalDuration > $1.totalDuration }
            if $0.visitCount != $1.visitCount { return $0.visitCount > $1.visitCount }
            return ($0.lastVisitAt ?? .distantPast) > ($1.lastVisitAt ?? .distantPast)
        }
    }
}

nonisolated struct HistoryPlaceRecordSnapshot: Hashable, Sendable {
    let id: UUID
    let name: String
    let totalDuration: TimeInterval
    let visitCount: Int
    let distinctDayCount: Int
    let lastVisitAt: Date?
    let isFavorite: Bool
    let isExcluded: Bool
}

nonisolated struct PlaceAnalyticsEngine: Sendable {
    func snapshot(
        visits: [PlaceVisitSnapshot],
        periodStart: Date,
        now: Date
    ) -> PlaceAnalyticsSnapshot {
        let included = visits.filter { !$0.isExcluded && $0.arrivalDate <= now }
        guard !included.isEmpty else { return .empty }

        let intervals = included.compactMap { visit -> (PlaceVisitSnapshot, Date, Date)? in
            let end = min(visit.departureDate ?? now, now)
            guard end > visit.arrivalDate else { return nil }
            return (visit, visit.arrivalDate, end)
        }
        guard !intervals.isEmpty else { return .empty }

        let durations = intervals.map { $0.2.timeIntervalSince($0.1) }
        var trendDurations: [Date: TimeInterval] = [:]
        var heatmapDurations: [String: TimeInterval] = [:]

        for (visit, start, end) in intervals {
            let boundedStart = max(start, periodStart)
            guard end > boundedStart else { continue }
            accumulate(
                from: boundedStart,
                to: end,
                timeZoneIdentifier: visit.timeZoneIdentifier,
                trend: &trendDurations,
                heatmap: &heatmapDurations
            )
        }

        let trend = trendDurations.map { PlaceTrendBucket(day: $0.key, duration: $0.value) }
            .sorted { $0.day < $1.day }
        let heatmap = heatmapDurations.compactMap { key, duration -> PlaceHeatmapBucket? in
            let parts = key.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 2 else { return nil }
            return PlaceHeatmapBucket(weekday: parts[0], hour: parts[1], duration: duration)
        }.sorted {
            $0.weekday == $1.weekday ? $0.hour < $1.hour : $0.weekday < $1.weekday
        }
        let dayKeys = Set(intervals.map { visit, _, _ in
            calendar(for: visit.timeZoneIdentifier).startOfDay(for: visit.arrivalDate)
        })

        return PlaceAnalyticsSnapshot(
            currentVisit: included.first { $0.departureDate == nil },
            periodDuration: trend.reduce(0) { $0 + $1.duration },
            allTimeDuration: durations.reduce(0, +),
            visitCount: intervals.count,
            distinctDayCount: dayKeys.count,
            averageDuration: durations.reduce(0, +) / Double(durations.count),
            longestDuration: durations.max() ?? 0,
            firstVisitAt: intervals.map { $0.1 }.min(),
            lastVisitAt: intervals.map { $0.2 }.max(),
            trend: trend,
            heatmap: heatmap
        )
    }

    private func accumulate(
        from start: Date,
        to end: Date,
        timeZoneIdentifier: String,
        trend: inout [Date: TimeInterval],
        heatmap: inout [String: TimeInterval]
    ) {
        let calendar = calendar(for: timeZoneIdentifier)
        var cursor = start
        while cursor < end {
            let day = calendar.startOfDay(for: cursor)
            let nextHour = calendar.nextDate(
                after: cursor,
                matching: DateComponents(minute: 0, second: 0),
                matchingPolicy: .nextTime,
                repeatedTimePolicy: .first,
                direction: .forward
            ) ?? end
            let segmentEnd = min(end, max(nextHour, cursor.addingTimeInterval(1)))
            let duration = segmentEnd.timeIntervalSince(cursor)
            let components = calendar.dateComponents([.weekday, .hour], from: cursor)
            trend[day, default: 0] += duration
            if let weekday = components.weekday, let hour = components.hour {
                heatmap["\(weekday)-\(hour)", default: 0] += duration
            }
            cursor = segmentEnd
        }
    }

    private func calendar(for timeZoneIdentifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        return calendar
    }
}

nonisolated struct PlaceSuggestionInput: Hashable, Sendable {
    let id: UUID
    let visits: [PlaceVisitSnapshot]
    let dismissedSuggestion: PlaceLabelSuggestion?
}

nonisolated struct PlaceLabelSuggestionEngine: Sendable {
    func suggestions(for places: [PlaceSuggestionInput], now: Date) -> [UUID: PlaceLabelSuggestion] {
        let homeScores = rankedScores(for: places, window: .home, now: now)
        var result: [UUID: PlaceLabelSuggestion] = [:]
        let homeID: UUID?
        if let first = homeScores.first,
           first.duration >= (homeScores.dropFirst().first?.duration ?? 0) * 1.5,
           first.place.dismissedSuggestion != PlaceLabelSuggestion.home {
            result[first.place.id] = .home
            homeID = first.place.id
        } else {
            homeID = nil
        }

        let workCandidates = places.filter { $0.id != homeID }
        let workScores = rankedScores(for: workCandidates, window: .work, now: now)
        if let first = workScores.first,
           first.duration >= (workScores.dropFirst().first?.duration ?? 0) * 1.5,
           first.place.dismissedSuggestion != PlaceLabelSuggestion.work {
            result[first.place.id] = .work
        }
        return result
    }

    private enum Window { case home, work }

    private struct Score {
        let place: PlaceSuggestionInput
        let duration: TimeInterval
        let distinctDays: Int
    }

    private func rankedScores(
        for places: [PlaceSuggestionInput],
        window: Window,
        now: Date
    ) -> [Score] {
        var scores: [Score] = []
        for place in places {
            let value = score(place.visits, window: window, now: now)
            if value.duration >= 6 * 3_600, value.distinctDays >= 3 {
                scores.append(Score(place: place, duration: value.duration, distinctDays: value.distinctDays))
            }
        }
        return scores.sorted { $0.duration > $1.duration }
    }

    private func score(
        _ visits: [PlaceVisitSnapshot],
        window: Window,
        now: Date
    ) -> (duration: TimeInterval, distinctDays: Int) {
        var duration: TimeInterval = 0
        var days = Set<Date>()
        for visit in visits where !visit.isExcluded {
            let end = min(visit.departureDate ?? now, now)
            guard end > visit.arrivalDate else { continue }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: visit.timeZoneIdentifier) ?? .current
            var cursor = visit.arrivalDate
            while cursor < end {
                let next = min(end, cursor.addingTimeInterval(15 * 60))
                let components = calendar.dateComponents([.weekday, .hour], from: cursor)
                let hour = components.hour ?? 0
                let weekday = components.weekday ?? 1
                let matches = switch window {
                case .home: hour >= 20 || hour < 8
                case .work: (2...6).contains(weekday) && (8..<18).contains(hour)
                }
                if matches {
                    duration += next.timeIntervalSince(cursor)
                    days.insert(calendar.startOfDay(for: cursor))
                }
                cursor = next
            }
        }
        return (duration, days.count)
    }
}
