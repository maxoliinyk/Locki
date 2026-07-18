//
//  BackupArchive.swift
//  Locki
//
//  Created by Max Oliinyk on 18.07.2026.
//

import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let lockiBackup = UTType(exportedAs: "com.maxoliinyk.locki.backup", conformingTo: .data)
}

nonisolated struct LockiBackupEnvelope: Codable, Equatable, Sendable {
    static let identifier = "com.maxoliinyk.Locki.backup"
    static let currentSchemaVersion = 2

    let identifier: String
    let schemaVersion: Int
    let exportedAt: Date
    let payload: LockiBackupPayload

    init(
        identifier: String = Self.identifier,
        schemaVersion: Int = Self.currentSchemaVersion,
        exportedAt: Date = .now,
        payload: LockiBackupPayload
    ) {
        self.identifier = identifier
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.payload = payload
    }
}

nonisolated struct LockiBackupPayload: Codable, Equatable, Sendable {
    let coverage: [BackupCoverageChunk]
    let trajectory: [BackupTrajectoryChunk]
    let trips: [BackupTrip]
    let visits: [BackupVisit]
    let places: [BackupPlace]
    let routes: [BackupRoute]
    let gaps: [BackupGap]
    let suggestionPreferences: [BackupSuggestionPreference]
}

nonisolated struct BackupCoverageChunk: Codable, Equatable, Sendable {
    let x: Int
    let y: Int
    let zoom: Int
    let maskData: Data
}

nonisolated struct BackupHistoryPoint: Codable, Equatable, Sendable {
    let latitudeE5: Int32
    let longitudeE5: Int32
    let timestampSeconds: Int64
    let accuracyBucketMeters: UInt8
    let speedHalfMetersPerSecond: UInt16?
    let courseFiveDegrees: UInt8?
    let timeZoneIdentifier: String

    init(_ point: HistoryPoint) {
        latitudeE5 = point.latitudeE5
        longitudeE5 = point.longitudeE5
        timestampSeconds = point.timestampSeconds
        accuracyBucketMeters = point.accuracyBucketMeters
        speedHalfMetersPerSecond = point.speedHalfMetersPerSecond
        courseFiveDegrees = point.courseFiveDegrees
        timeZoneIdentifier = point.timeZoneIdentifier
    }

    var historyPoint: HistoryPoint {
        HistoryPoint(
            latitudeE5: latitudeE5,
            longitudeE5: longitudeE5,
            timestampSeconds: timestampSeconds,
            accuracyBucketMeters: accuracyBucketMeters,
            speedHalfMetersPerSecond: speedHalfMetersPerSecond,
            courseFiveDegrees: courseFiveDegrees,
            timeZoneIdentifier: timeZoneIdentifier
        )
    }
}

nonisolated struct BackupTrajectoryChunk: Codable, Equatable, Sendable {
    let id: UUID
    let tripID: UUID
    let sequence: Int
    let points: [BackupHistoryPoint]
}

nonisolated struct BackupTrip: Codable, Equatable, Sendable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date?
    let startTimeZoneIdentifier: String
    let endTimeZoneIdentifier: String?
    let originPlaceID: UUID?
    let destinationPlaceID: UUID?
    let distanceMeters: Double
    let movingDuration: TimeInterval
    let elapsedDuration: TimeInterval
    let averageMovingSpeedMetersPerSecond: Double
    let peakSpeedMetersPerSecond: Double
    let modeRawValue: String
    let modeConfidence: Double
    let completeness: Double
    let isExcluded: Bool
    let routePatternID: UUID?
}

nonisolated struct BackupVisit: Codable, Equatable, Sendable {
    let id: UUID
    let placeID: UUID?
    let arrivalDate: Date
    let departureDate: Date?
    let timeZoneIdentifier: String
    let latitude: Double
    let longitude: Double
    let radiusMeters: Double
    let sourceRawValue: String
    let quality: Double
    let isExcluded: Bool
}

nonisolated struct BackupPlace: Codable, Equatable, Sendable {
    let id: UUID
    let latitude: Double
    let longitude: Double
    let radiusMeters: Double
    let name: String
    let category: String?
    let labelSourceRawValue: String
    let isFavorite: Bool
    let isExcluded: Bool
}

nonisolated struct BackupRoute: Codable, Equatable, Sendable {
    let id: UUID
    let originPlaceID: UUID
    let destinationPlaceID: UUID
    let name: String?
    let representativePoints: [BackupHistoryPoint]
    let isFavorite: Bool
    let isExcluded: Bool
    let isManuallyEdited: Bool
}

nonisolated struct BackupGap: Codable, Equatable, Sendable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date?
    let reasonRawValue: String
    let diagnosisRawValue: String?
    let resolutionRawValue: String?
    let resolvedAt: Date?
    let travelModeRawValue: String?
    let estimatedDistanceMeters: Double?
    let estimatedTravelTime: TimeInterval?
    let estimatedRoute: [BackupGapCoordinate]?

    init(
        id: UUID,
        startedAt: Date,
        endedAt: Date?,
        reasonRawValue: String,
        diagnosisRawValue: String? = nil,
        resolutionRawValue: String? = nil,
        resolvedAt: Date? = nil,
        travelModeRawValue: String? = nil,
        estimatedDistanceMeters: Double? = nil,
        estimatedTravelTime: TimeInterval? = nil,
        estimatedRoute: [BackupGapCoordinate]? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.reasonRawValue = reasonRawValue
        self.diagnosisRawValue = diagnosisRawValue
        self.resolutionRawValue = resolutionRawValue
        self.resolvedAt = resolvedAt
        self.travelModeRawValue = travelModeRawValue
        self.estimatedDistanceMeters = estimatedDistanceMeters
        self.estimatedTravelTime = estimatedTravelTime
        self.estimatedRoute = estimatedRoute
    }
}

nonisolated struct BackupGapCoordinate: Codable, Equatable, Sendable {
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

nonisolated struct BackupSuggestionPreference: Codable, Equatable, Sendable {
    let placeID: UUID
    let dismissedSuggestionRawValue: String
}

nonisolated struct BackupPreview: Equatable, Sendable {
    let exportedAt: Date
    let placeCount: Int
    let tripCount: Int
    let visitCount: Int
    let coverageChunkCount: Int
}

nonisolated struct BackupImportResult: Equatable, Sendable {
    let insertedPlaces: Int
    let insertedTrips: Int
    let insertedVisits: Int
    let insertedRoutes: Int
    let insertedGaps: Int
    let insertedTrajectoryChunks: Int
    let mergedCoverageCells: Int

    var insertedRecordCount: Int {
        insertedPlaces + insertedTrips + insertedVisits + insertedRoutes + insertedGaps + insertedTrajectoryChunks
    }
}

nonisolated enum BackupArchiveError: LocalizedError, Equatable, Sendable {
    case fileTooLarge
    case invalidEncoding
    case wrongIdentifier
    case unsupportedVersion(Int)
    case tooManyRecords
    case duplicateIdentifier
    case invalidCoverage
    case invalidCoordinate
    case invalidDateRange
    case invalidValue
    case danglingRelationship
    case emptyTrajectory

    var errorDescription: String? {
        switch self {
        case .fileTooLarge: "This backup is too large to import safely."
        case .invalidEncoding: "This file is not a valid Locki backup."
        case .wrongIdentifier: "This file was not created as a Locki backup."
        case .unsupportedVersion: "This backup was created by an unsupported version of Locki."
        case .tooManyRecords: "This backup contains too many records to import safely."
        case .duplicateIdentifier: "This backup contains duplicate records."
        case .invalidCoverage: "This backup contains invalid exploration coverage."
        case .invalidCoordinate: "This backup contains an invalid location."
        case .invalidDateRange: "This backup contains an invalid date range."
        case .invalidValue: "This backup contains an invalid value."
        case .danglingRelationship: "This backup contains incomplete related data."
        case .emptyTrajectory: "This backup contains an empty route segment."
        }
    }
}

nonisolated enum BackupArchiveCodec {
    static let maximumFileSize = 100 * 1_024 * 1_024
    private static let maximumRecordCount = 1_000_000
    private static let maximumPointCount = 5_000_000

    static func encode(_ envelope: LockiBackupEnvelope) throws -> Data {
        try validate(envelope)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(envelope)
    }

    static func decode(_ data: Data) throws -> LockiBackupEnvelope {
        guard data.count <= maximumFileSize else { throw BackupArchiveError.fileTooLarge }
        let envelope: LockiBackupEnvelope
        do {
            envelope = try PropertyListDecoder().decode(LockiBackupEnvelope.self, from: data)
        } catch {
            throw BackupArchiveError.invalidEncoding
        }
        try validate(envelope)
        return envelope
    }

    static func preview(_ envelope: LockiBackupEnvelope) -> BackupPreview {
        BackupPreview(
            exportedAt: envelope.exportedAt,
            placeCount: envelope.payload.places.count,
            tripCount: envelope.payload.trips.count,
            visitCount: envelope.payload.visits.count,
            coverageChunkCount: envelope.payload.coverage.count
        )
    }

    static func validate(_ envelope: LockiBackupEnvelope) throws {
        guard envelope.identifier == LockiBackupEnvelope.identifier else {
            throw BackupArchiveError.wrongIdentifier
        }
        guard (1...LockiBackupEnvelope.currentSchemaVersion).contains(envelope.schemaVersion) else {
            throw BackupArchiveError.unsupportedVersion(envelope.schemaVersion)
        }

        let payload = envelope.payload
        let recordCount = payload.coverage.count + payload.trajectory.count + payload.trips.count
            + payload.visits.count + payload.places.count + payload.routes.count
            + payload.gaps.count + payload.suggestionPreferences.count
        let pointCount = payload.trajectory.reduce(0) { $0 + $1.points.count }
            + payload.routes.reduce(0) { $0 + $1.representativePoints.count }
            + payload.gaps.reduce(0) { $0 + ($1.estimatedRoute?.count ?? 0) }
        guard recordCount <= maximumRecordCount, pointCount <= maximumPointCount else {
            throw BackupArchiveError.tooManyRecords
        }

        try requireUnique(payload.trajectory.map(\.id))
        try requireUnique(payload.trips.map(\.id))
        try requireUnique(payload.visits.map(\.id))
        try requireUnique(payload.places.map(\.id))
        try requireUnique(payload.routes.map(\.id))
        try requireUnique(payload.gaps.map(\.id))
        try requireUnique(payload.suggestionPreferences.map(\.placeID))
        try requireUnique(payload.coverage.map { "\($0.zoom)/\($0.x)/\($0.y)" })
        try requireUnique(payload.trajectory.map { "\($0.tripID.uuidString)|\($0.sequence)" })

        let placeIDs = Set(payload.places.map(\.id))
        let tripIDs = Set(payload.trips.map(\.id))
        let routeIDs = Set(payload.routes.map(\.id))
        guard payload.visits.allSatisfy({ $0.placeID.map(placeIDs.contains) ?? true }),
              payload.trajectory.allSatisfy({ tripIDs.contains($0.tripID) }),
              payload.routes.allSatisfy({ placeIDs.contains($0.originPlaceID) && placeIDs.contains($0.destinationPlaceID) }),
              payload.trips.allSatisfy({
                  ($0.originPlaceID.map(placeIDs.contains) ?? true)
                      && ($0.destinationPlaceID.map(placeIDs.contains) ?? true)
                      && ($0.routePatternID.map(routeIDs.contains) ?? true)
              }),
              payload.suggestionPreferences.allSatisfy({ placeIDs.contains($0.placeID) }) else {
            throw BackupArchiveError.danglingRelationship
        }

        let chunkZoom = ExplorationConfiguration.streetPrecise.chunkZoom
        let chunkLimit = 1 << chunkZoom
        guard payload.coverage.allSatisfy({
            $0.zoom == chunkZoom
                && (0..<chunkLimit).contains($0.x)
                && (0..<chunkLimit).contains($0.y)
                && $0.maskData.count == CoverageMask.byteCount
        }) else {
            throw BackupArchiveError.invalidCoverage
        }

        guard payload.places.allSatisfy({ validCoordinate($0.latitude, $0.longitude) && validRadius($0.radiusMeters) }),
              payload.visits.allSatisfy({ validCoordinate($0.latitude, $0.longitude) && validRadius($0.radiusMeters) }),
              payload.trajectory.flatMap(\.points).allSatisfy(validPoint),
              payload.routes.flatMap(\.representativePoints).allSatisfy(validPoint),
              payload.gaps.flatMap({ $0.estimatedRoute ?? [] }).allSatisfy(validGapCoordinate) else {
            throw BackupArchiveError.invalidCoordinate
        }

        guard payload.trajectory.allSatisfy({ !$0.points.isEmpty && $0.sequence >= 0 }),
              payload.routes.allSatisfy({ !$0.representativePoints.isEmpty }) else {
            throw BackupArchiveError.emptyTrajectory
        }
        let latestAllowedDate = Date.now + 24 * 60 * 60
        guard validDate(envelope.exportedAt, latestAllowedDate: latestAllowedDate),
              payload.trips.allSatisfy({
                  validRange(start: $0.startedAt, end: $0.endedAt, latestAllowedDate: latestAllowedDate)
                      && ($0.endedAt != nil || $0.startedAt <= envelope.exportedAt)
                      && validTimeZone($0.startTimeZoneIdentifier)
                      && ($0.endTimeZoneIdentifier.map(validTimeZone) ?? true)
              }),
              payload.visits.allSatisfy({
                  validRange(start: $0.arrivalDate, end: $0.departureDate, latestAllowedDate: latestAllowedDate)
                      && ($0.departureDate != nil || $0.arrivalDate <= envelope.exportedAt)
                      && validTimeZone($0.timeZoneIdentifier)
              }),
              payload.gaps.allSatisfy({
                  validRange(start: $0.startedAt, end: $0.endedAt, latestAllowedDate: latestAllowedDate)
                      && ($0.endedAt != nil || $0.startedAt <= envelope.exportedAt)
                      && ($0.resolvedAt.map {
                          validDate($0, latestAllowedDate: latestAllowedDate)
                      } ?? true)
              }),
              payload.trajectory.flatMap(\.points).allSatisfy({
                  validDate(
                      Date(timeIntervalSince1970: TimeInterval($0.timestampSeconds)),
                      latestAllowedDate: latestAllowedDate
                  ) && validTimeZone($0.timeZoneIdentifier)
              }),
              payload.routes.flatMap(\.representativePoints).allSatisfy({
                  validDate(
                      Date(timeIntervalSince1970: TimeInterval($0.timestampSeconds)),
                      latestAllowedDate: latestAllowedDate
                  ) && validTimeZone($0.timeZoneIdentifier)
              }) else {
            throw BackupArchiveError.invalidDateRange
        }
        let tripsByID = Dictionary(uniqueKeysWithValues: payload.trips.map { ($0.id, $0) })
        guard payload.trajectory.allSatisfy({ chunk in
            guard let trip = tripsByID[chunk.tripID] else { return false }
            let timestamps = chunk.points.map(\.timestampSeconds)
            let ordered = zip(timestamps, timestamps.dropFirst()).allSatisfy { $0.0 <= $0.1 }
            let lower = trip.startedAt.addingTimeInterval(-1)
            let upper = (trip.endedAt ?? envelope.exportedAt).addingTimeInterval(1)
            return ordered && chunk.points.allSatisfy {
                let date = Date(timeIntervalSince1970: TimeInterval($0.timestampSeconds))
                return date >= lower && date <= upper
            }
        }) else {
            throw BackupArchiveError.invalidDateRange
        }
        guard payload.trips.allSatisfy({
            validNonnegative($0.distanceMeters)
                && validNonnegative($0.movingDuration)
                && validNonnegative($0.elapsedDuration)
                && validNonnegative($0.averageMovingSpeedMetersPerSecond)
                && validNonnegative($0.peakSpeedMetersPerSecond)
                && $0.modeConfidence.isFinite && (0...1).contains($0.modeConfidence)
                && $0.completeness.isFinite && (0...1).contains($0.completeness)
                && MovementMode(rawValue: $0.modeRawValue) != nil
        }), payload.visits.allSatisfy({
            $0.quality.isFinite && (0...1).contains($0.quality) && !$0.sourceRawValue.isEmpty
        }), payload.gaps.allSatisfy({ gap in
            guard HistoryGapReason(rawValue: gap.reasonRawValue) != nil,
                  gap.diagnosisRawValue.map({ HistoryGapDiagnosis(rawValue: $0) != nil }) ?? true,
                  gap.resolutionRawValue.map({ HistoryGapResolution(rawValue: $0) != nil }) ?? true,
                  gap.travelModeRawValue.map({ HistoryGapTravelMode(rawValue: $0) != nil }) ?? true,
                  gap.estimatedDistanceMeters.map(validNonnegative) ?? true,
                  gap.estimatedTravelTime.map(validNonnegative) ?? true else { return false }
            if gap.resolutionRawValue == HistoryGapResolution.confirmedRoute.rawValue {
                return (gap.estimatedRoute?.count ?? 0) >= 2
            }
            return true
        }),
              payload.suggestionPreferences.allSatisfy({ PlaceLabelSuggestion(rawValue: $0.dismissedSuggestionRawValue) != nil }),
              payload.places.allSatisfy({
                  !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && $0.name.count <= 500
                      && ($0.category?.count ?? 0) <= 500
                      && !$0.labelSourceRawValue.isEmpty
              }),
              payload.routes.allSatisfy({ ($0.name?.count ?? 0) <= 500 }) else {
            throw BackupArchiveError.invalidValue
        }
    }

    private static func requireUnique<T: Hashable>(_ values: [T]) throws {
        guard Set(values).count == values.count else { throw BackupArchiveError.duplicateIdentifier }
    }

    private static func validCoordinate(_ latitude: Double, _ longitude: Double) -> Bool {
        latitude.isFinite && longitude.isFinite
            && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }

    private static func validRadius(_ value: Double) -> Bool {
        value.isFinite && (0...100_000).contains(value)
    }

    private static func validPoint(_ point: BackupHistoryPoint) -> Bool {
        (-9_000_000...9_000_000).contains(point.latitudeE5)
            && (-18_000_000...18_000_000).contains(point.longitudeE5)
            && point.courseFiveDegrees.map({ $0 < 72 }) ?? true
            && !point.timeZoneIdentifier.isEmpty
    }

    private static func validGapCoordinate(_ coordinate: BackupGapCoordinate) -> Bool {
        (-9_000_000...9_000_000).contains(coordinate.latitudeE5)
            && (-18_000_000...18_000_000).contains(coordinate.longitudeE5)
    }

    private static func validRange(start: Date, end: Date?, latestAllowedDate: Date) -> Bool {
        validDate(start, latestAllowedDate: latestAllowedDate)
            && (end.map { validDate($0, latestAllowedDate: latestAllowedDate) } ?? true)
            && (end.map { $0 >= start } ?? true)
    }

    private static func validDate(_ date: Date, latestAllowedDate: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite
            && date >= Date(timeIntervalSince1970: 0)
            && date <= latestAllowedDate
    }

    private static func validTimeZone(_ identifier: String) -> Bool {
        TimeZone(identifier: identifier) != nil
    }

    private static func validNonnegative(_ value: Double) -> Bool {
        value.isFinite && value >= 0
    }
}
