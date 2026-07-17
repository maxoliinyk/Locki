//
//  HistoryModels.swift
//  Locki
//
//  Created by Max Oliinyk on 17.07.2026.
//

import CoreLocation
import Foundation

nonisolated enum HistoryGapReason: String, Codable, Hashable, Sendable {
    case authorization
    case reducedAccuracy
    case discontinuity
    case disabled
    case persistence
    case unavailable
}

nonisolated enum HistoryEvent: Hashable, Sendable {
    case sample(HistoryLocationSample)
    case visit(SystemVisitSample)
    case dwellCheck(Date)
    case gap(start: Date, end: Date?, reason: HistoryGapReason)
}

nonisolated struct HistoryLocationSample: Codable, Hashable, Sendable {
    let coordinate: GeoCoordinate
    let horizontalAccuracyMeters: Double
    let speedMetersPerSecond: Double?
    let courseDegrees: Double?
    let timestamp: Date
    let timeZoneIdentifier: String
    let hasPreciseAccuracy: Bool

    init(
        coordinate: GeoCoordinate,
        horizontalAccuracyMeters: Double,
        speedMetersPerSecond: Double? = nil,
        courseDegrees: Double? = nil,
        timestamp: Date,
        timeZoneIdentifier: String = TimeZone.current.identifier,
        hasPreciseAccuracy: Bool = true
    ) {
        self.coordinate = coordinate
        self.horizontalAccuracyMeters = horizontalAccuracyMeters
        self.speedMetersPerSecond = speedMetersPerSecond
        self.courseDegrees = courseDegrees
        self.timestamp = timestamp
        self.timeZoneIdentifier = timeZoneIdentifier
        self.hasPreciseAccuracy = hasPreciseAccuracy
    }

    init(location: CLLocation, hasPreciseAccuracy: Bool) {
        self.init(
            coordinate: GeoCoordinate(location.coordinate),
            horizontalAccuracyMeters: location.horizontalAccuracy,
            speedMetersPerSecond: location.speed >= 0 ? location.speed : nil,
            courseDegrees: location.course >= 0 && location.courseAccuracy >= 0 ? location.course : nil,
            timestamp: location.timestamp,
            hasPreciseAccuracy: hasPreciseAccuracy
        )
    }
}

nonisolated struct SystemVisitSample: Codable, Hashable, Sendable {
    let coordinate: GeoCoordinate
    let horizontalAccuracyMeters: Double
    let arrivalDate: Date
    let departureDate: Date?
    let timeZoneIdentifier: String
}

nonisolated struct HistoryPoint: Codable, Hashable, Sendable {
    let latitudeE5: Int32
    let longitudeE5: Int32
    let timestampSeconds: Int64
    let accuracyBucketMeters: UInt8
    let speedHalfMetersPerSecond: UInt16?
    let courseFiveDegrees: UInt8?
    let timeZoneIdentifier: String

    init(sample: HistoryLocationSample) {
        latitudeE5 = Int32((sample.coordinate.latitude * 100_000).rounded())
        longitudeE5 = Int32((sample.coordinate.longitude * 100_000).rounded())
        timestampSeconds = Int64(sample.timestamp.timeIntervalSince1970.rounded())
        accuracyBucketMeters = UInt8(clamping: Int(ceil(sample.horizontalAccuracyMeters / 5) * 5))
        speedHalfMetersPerSecond = sample.speedMetersPerSecond.map {
            UInt16(clamping: Int(($0 * 2).rounded()))
        }
        courseFiveDegrees = sample.courseDegrees.map {
            UInt8(clamping: Int(($0 / 5).rounded()).quotientAndRemainder(dividingBy: 72).remainder)
        }
        timeZoneIdentifier = sample.timeZoneIdentifier
    }

    var coordinate: GeoCoordinate {
        GeoCoordinate(
            latitude: Double(latitudeE5) / 100_000,
            longitude: Double(longitudeE5) / 100_000
        )
    }

    var timestamp: Date { Date(timeIntervalSince1970: TimeInterval(timestampSeconds)) }
    var speedMetersPerSecond: Double? { speedHalfMetersPerSecond.map { Double($0) / 2 } }
    var courseDegrees: Double? { courseFiveDegrees.map { Double($0) * 5 } }
}

nonisolated enum MovementMode: String, Codable, CaseIterable, Hashable, Sendable {
    case walking
    case cycling
    case motorized
    case unknown
}

nonisolated struct HistoryOverview: Hashable, Sendable {
    var distanceMeters: Double = 0
    var movingDuration: TimeInterval = 0
    var placeDuration: TimeInterval = 0
    var tripCount: Int = 0
    var visitCount: Int = 0
    var placeCount: Int = 0
    var trackedDayCount: Int = 0
    var gapCount: Int = 0
    var encodedByteCount: Int = 0
    var latestEventAt: Date?
}

nonisolated struct HistoryConfiguration: Hashable, Sendable {
    let maximumHorizontalAccuracyMeters: Double
    let maximumSampleAge: TimeInterval
    let futureTimestampTolerance: TimeInterval
    let maximumSpeedMetersPerSecond: Double
    let minimumRetainedDistanceMeters: Double
    let maximumRetainedInterval: TimeInterval
    let minimumHeadingChangeDegrees: Double
    let tripGapInterval: TimeInterval
    let minimumVisitDuration: TimeInterval
    let baseVisitRadiusMeters: Double
    let maximumVisitRadiusMeters: Double
    let visitExitDuration: TimeInterval
    let minimumTripDistanceMeters: Double
    let minimumTripDuration: TimeInterval
    let pointsPerChunk: Int

    static let standard = HistoryConfiguration(
        maximumHorizontalAccuracyMeters: 35,
        maximumSampleAge: 120,
        futureTimestampTolerance: 10,
        maximumSpeedMetersPerSecond: 80,
        minimumRetainedDistanceMeters: 15,
        maximumRetainedInterval: 30,
        minimumHeadingChangeDegrees: 20,
        tripGapInterval: 10 * 60,
        minimumVisitDuration: 10 * 60,
        baseVisitRadiusMeters: 35,
        maximumVisitRadiusMeters: 100,
        visitExitDuration: 5 * 60,
        minimumTripDistanceMeters: 100,
        minimumTripDuration: 2 * 60,
        pointsPerChunk: 256
    )
}

nonisolated struct PlaceVisitSnapshot: Hashable, Sendable {
    let id: UUID
    let arrivalDate: Date
    let departureDate: Date?
    let timeZoneIdentifier: String
    let isExcluded: Bool
}

nonisolated struct PlaceTrendBucket: Identifiable, Hashable, Sendable {
    let day: Date
    let duration: TimeInterval

    var id: Date { day }
}

nonisolated struct PlaceHeatmapBucket: Identifiable, Hashable, Sendable {
    let weekday: Int
    let hour: Int
    let duration: TimeInterval

    var id: String { "\(weekday)-\(hour)" }
}

nonisolated struct PlaceAnalyticsSnapshot: Hashable, Sendable {
    let currentVisit: PlaceVisitSnapshot?
    let periodDuration: TimeInterval
    let allTimeDuration: TimeInterval
    let visitCount: Int
    let distinctDayCount: Int
    let averageDuration: TimeInterval
    let longestDuration: TimeInterval
    let firstVisitAt: Date?
    let lastVisitAt: Date?
    let trend: [PlaceTrendBucket]
    let heatmap: [PlaceHeatmapBucket]

    static let empty = PlaceAnalyticsSnapshot(
        currentVisit: nil,
        periodDuration: 0,
        allTimeDuration: 0,
        visitCount: 0,
        distinctDayCount: 0,
        averageDuration: 0,
        longestDuration: 0,
        firstVisitAt: nil,
        lastVisitAt: nil,
        trend: [],
        heatmap: []
    )
}

nonisolated enum PlaceLabelSuggestion: String, Codable, Hashable, Sendable {
    case home = "Home"
    case work = "Work"
}

nonisolated struct HistoryExport: Codable, Sendable {
    let schemaVersion: Int
    let exportedAt: Date
    let trips: [ExportedTrip]
    let visits: [ExportedVisit]
    let places: [ExportedPlace]
    let gaps: [ExportedGap]
}

nonisolated struct ExportedTrip: Codable, Sendable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date?
    let startTimeZoneIdentifier: String
    let endTimeZoneIdentifier: String?
    let distanceMeters: Double
    let movingDuration: TimeInterval
    let mode: MovementMode
    let points: [HistoryPoint]
}

nonisolated struct ExportedVisit: Codable, Sendable {
    let id: UUID
    let placeID: UUID?
    let arrivalDate: Date
    let departureDate: Date?
    let timeZoneIdentifier: String
    let latitude: Double
    let longitude: Double
    let radiusMeters: Double
}

nonisolated struct ExportedPlace: Codable, Sendable {
    let id: UUID
    let name: String
    let category: String?
    let latitude: Double
    let longitude: Double
    let isFavorite: Bool
}

nonisolated struct ExportedGap: Codable, Sendable {
    let startedAt: Date
    let endedAt: Date?
    let reason: HistoryGapReason
}
