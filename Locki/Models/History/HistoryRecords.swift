//
//  HistoryRecords.swift
//  Locki
//
//  Created by Max Oliinyk on 17.07.2026.
//

import Foundation
import SwiftData

@Model
final class HistoryMetadataRecord {
    @Attribute(.unique) var key: String
    var enabledAt: Date?
    var inferenceVersion: Int
    var lastProcessedAt: Date?
    var lastLatitude: Double?
    var lastLongitude: Double?
    var lastAccuracyMeters: Double?
    var lastSpeedMetersPerSecond: Double?
    var lastCourseDegrees: Double?
    var lastTimeZoneIdentifier: String?
    var openTripID: UUID?
    var openVisitID: UUID?
    var latestPlaceID: UUID?
    var candidateStartedAt: Date?
    var candidateLatitude: Double?
    var candidateLongitude: Double?
    var candidateAccuracyMeters: Double?
    var candidateCount: Int
    var encodedByteCount: Int

    init(key: String = "primary") {
        self.key = key
        inferenceVersion = 1
        candidateCount = 0
        encodedByteCount = 0
    }
}

@Model
final class TrajectoryChunkRecord {
    @Attribute(.unique) var id: UUID
    var tripID: UUID
    var sequence: Int
    var startedAt: Date
    var endedAt: Date
    var minimumLatitude: Double
    var maximumLatitude: Double
    var minimumLongitude: Double
    var maximumLongitude: Double
    var pointCount: Int
    @Attribute(.externalStorage) var encodedPoints: Data

    init(id: UUID = UUID(), tripID: UUID, sequence: Int, points: [HistoryPoint]) throws {
        self.id = id
        self.tripID = tripID
        self.sequence = sequence
        let first = points.first
        let coordinates = points.map(\.coordinate)
        startedAt = first?.timestamp ?? .distantPast
        endedAt = points.last?.timestamp ?? .distantPast
        minimumLatitude = coordinates.map(\.latitude).min() ?? 0
        maximumLatitude = coordinates.map(\.latitude).max() ?? 0
        minimumLongitude = coordinates.map(\.longitude).min() ?? 0
        maximumLongitude = coordinates.map(\.longitude).max() ?? 0
        pointCount = points.count
        encodedPoints = try HistoryPointCodec.encode(points)
    }

    var points: [HistoryPoint] { (try? HistoryPointCodec.decode(encodedPoints)) ?? [] }

    func replacePoints(_ points: [HistoryPoint]) throws {
        guard let first = points.first, let last = points.last else { return }
        let coordinates = points.map(\.coordinate)
        startedAt = first.timestamp
        endedAt = last.timestamp
        minimumLatitude = coordinates.map(\.latitude).min() ?? 0
        maximumLatitude = coordinates.map(\.latitude).max() ?? 0
        minimumLongitude = coordinates.map(\.longitude).min() ?? 0
        maximumLongitude = coordinates.map(\.longitude).max() ?? 0
        pointCount = points.count
        encodedPoints = try HistoryPointCodec.encode(points)
    }
}

@Model
final class HistoryTripRecord {
    @Attribute(.unique) var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var startTimeZoneIdentifier: String
    var endTimeZoneIdentifier: String?
    var originPlaceID: UUID?
    var destinationPlaceID: UUID?
    var distanceMeters: Double
    var movingDuration: TimeInterval
    var elapsedDuration: TimeInterval
    var averageMovingSpeedMetersPerSecond: Double
    var peakSpeedMetersPerSecond: Double
    var modeRawValue: String
    var modeConfidence: Double
    var completeness: Double
    var isExcluded: Bool
    var routePatternID: UUID?

    init(
        id: UUID = UUID(),
        startedAt: Date,
        startTimeZoneIdentifier: String,
        originPlaceID: UUID? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.startTimeZoneIdentifier = startTimeZoneIdentifier
        self.originPlaceID = originPlaceID
        distanceMeters = 0
        movingDuration = 0
        elapsedDuration = 0
        averageMovingSpeedMetersPerSecond = 0
        peakSpeedMetersPerSecond = 0
        modeRawValue = MovementMode.unknown.rawValue
        modeConfidence = 0
        completeness = 1
        isExcluded = false
    }

    var mode: MovementMode { MovementMode(rawValue: modeRawValue) ?? .unknown }
}

@Model
final class HistoryVisitRecord {
    @Attribute(.unique) var id: UUID
    var placeID: UUID?
    var arrivalDate: Date
    var departureDate: Date?
    var timeZoneIdentifier: String
    var latitude: Double
    var longitude: Double
    var radiusMeters: Double
    var sourceRawValue: String
    var quality: Double
    var isExcluded: Bool

    init(
        id: UUID = UUID(),
        placeID: UUID? = nil,
        arrivalDate: Date,
        departureDate: Date? = nil,
        timeZoneIdentifier: String,
        latitude: Double,
        longitude: Double,
        radiusMeters: Double,
        sourceRawValue: String,
        quality: Double
    ) {
        self.id = id
        self.placeID = placeID
        self.arrivalDate = arrivalDate
        self.departureDate = departureDate
        self.timeZoneIdentifier = timeZoneIdentifier
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMeters = radiusMeters
        self.sourceRawValue = sourceRawValue
        self.quality = quality
        isExcluded = false
    }
}

@Model
final class HistoryPlaceRecord {
    @Attribute(.unique) var id: UUID
    var latitude: Double
    var longitude: Double
    var radiusMeters: Double
    var name: String
    var category: String?
    var labelSourceRawValue: String
    var isFavorite: Bool
    var isExcluded: Bool
    var totalDuration: TimeInterval
    var visitCount: Int
    var distinctDayCount: Int
    var firstVisitAt: Date?
    var lastVisitAt: Date?

    init(
        id: UUID = UUID(),
        latitude: Double,
        longitude: Double,
        radiusMeters: Double,
        name: String,
        labelSourceRawValue: String = "local"
    ) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMeters = radiusMeters
        self.name = name
        self.labelSourceRawValue = labelSourceRawValue
        isFavorite = false
        isExcluded = false
        totalDuration = 0
        visitCount = 0
        distinctDayCount = 0
    }
}

@Model
final class PlaceSuggestionPreferenceRecord {
    @Attribute(.unique) var placeID: UUID
    var dismissedSuggestionRawValue: String

    init(placeID: UUID, dismissedSuggestionRawValue: String) {
        self.placeID = placeID
        self.dismissedSuggestionRawValue = dismissedSuggestionRawValue
    }
}

@Model
final class HistoryRoutePatternRecord {
    @Attribute(.unique) var id: UUID
    var originPlaceID: UUID
    var destinationPlaceID: UUID
    var name: String?
    @Attribute(.externalStorage) var representativeGeometry: Data
    var tripCount: Int
    var distinctDayCount: Int
    var totalDistanceMeters: Double
    var totalDuration: TimeInterval
    var lastUsedAt: Date
    var isFavorite: Bool
    var isExcluded: Bool
    var isManuallyEdited: Bool

    init(
        id: UUID = UUID(),
        originPlaceID: UUID,
        destinationPlaceID: UUID,
        representativeGeometry: Data,
        lastUsedAt: Date
    ) {
        self.id = id
        self.originPlaceID = originPlaceID
        self.destinationPlaceID = destinationPlaceID
        self.representativeGeometry = representativeGeometry
        tripCount = 0
        distinctDayCount = 0
        totalDistanceMeters = 0
        totalDuration = 0
        self.lastUsedAt = lastUsedAt
        isFavorite = false
        isExcluded = false
        isManuallyEdited = false
    }
}

@Model
final class HistoryDailySummaryRecord {
    @Attribute(.unique) var key: String
    var dayStart: Date
    var timeZoneIdentifier: String
    var distanceMeters: Double
    var movingDuration: TimeInterval
    var placeDuration: TimeInterval
    var tripCount: Int
    var visitCount: Int
    var gapDuration: TimeInterval
    var peakSpeedMetersPerSecond: Double
    var completeness: Double

    init(dayStart: Date, timeZoneIdentifier: String) {
        key = Self.key(dayStart: dayStart, timeZoneIdentifier: timeZoneIdentifier)
        self.dayStart = dayStart
        self.timeZoneIdentifier = timeZoneIdentifier
        distanceMeters = 0
        movingDuration = 0
        placeDuration = 0
        tripCount = 0
        visitCount = 0
        gapDuration = 0
        peakSpeedMetersPerSecond = 0
        completeness = 1
    }

    static func key(dayStart: Date, timeZoneIdentifier: String) -> String {
        "\(Int(dayStart.timeIntervalSince1970))|\(timeZoneIdentifier)"
    }
}

@Model
final class HistoryGapRecord {
    @Attribute(.unique) var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var reasonRawValue: String
    var diagnosisRawValue: String?
    var resolutionRawValue: String = HistoryGapResolution.unresolved.rawValue
    var resolvedAt: Date?
    var travelModeRawValue: String?
    var estimatedDistanceMeters: Double?
    var estimatedTravelTime: TimeInterval?
    @Attribute(.externalStorage) var estimatedRouteData: Data?

    init(
        id: UUID = UUID(),
        startedAt: Date,
        endedAt: Date?,
        reason: HistoryGapReason,
        diagnosis: HistoryGapDiagnosis? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        reasonRawValue = reason.rawValue
        diagnosisRawValue = diagnosis?.rawValue
    }

    var reason: HistoryGapReason { HistoryGapReason(rawValue: reasonRawValue) ?? .unavailable }
    var diagnosis: HistoryGapDiagnosis? { diagnosisRawValue.flatMap(HistoryGapDiagnosis.init(rawValue:)) }
    var resolution: HistoryGapResolution {
        HistoryGapResolution(rawValue: resolutionRawValue) ?? .unresolved
    }
    var travelMode: HistoryGapTravelMode? {
        travelModeRawValue.flatMap(HistoryGapTravelMode.init(rawValue:))
    }
    var estimatedRoute: [GeoCoordinate] {
        guard let estimatedRouteData else { return [] }
        return (try? HistoryGapRouteCodec.decode(estimatedRouteData)) ?? []
    }
}

nonisolated enum HistoryGapRouteCodec {
    static func encode(_ coordinates: [GeoCoordinate]) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(coordinates.map(QuantizedGapCoordinate.init))
    }

    static func decode(_ data: Data) throws -> [GeoCoordinate] {
        try PropertyListDecoder().decode([QuantizedGapCoordinate].self, from: data).map(\.coordinate)
    }
}

nonisolated private struct QuantizedGapCoordinate: Codable, Sendable {
    let latitudeE5: Int32
    let longitudeE5: Int32

    init(_ coordinate: GeoCoordinate) {
        latitudeE5 = Int32((coordinate.latitude * 100_000).rounded())
        longitudeE5 = Int32((coordinate.longitude * 100_000).rounded())
    }

    var coordinate: GeoCoordinate {
        GeoCoordinate(
            latitude: Double(latitudeE5) / 100_000,
            longitude: Double(longitudeE5) / 100_000
        )
    }
}

nonisolated enum HistoryPointCodec {
    static func encode(_ points: [HistoryPoint]) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(points)
    }

    static func decode(_ data: Data) throws -> [HistoryPoint] {
        try PropertyListDecoder().decode([HistoryPoint].self, from: data)
    }
}
