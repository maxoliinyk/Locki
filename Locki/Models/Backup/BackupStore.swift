//
//  BackupStore.swift
//  Locki
//
//  Created by Max Oliinyk on 18.07.2026.
//

import Foundation
import SwiftData

@ModelActor
actor BackupStore {
    func exportData(exportedAt: Date = .now) throws -> Data {
        let coverage = try modelContext.fetch(FetchDescriptor<CoverageChunkRecord>()).map {
            BackupCoverageChunk(x: $0.x, y: $0.y, zoom: $0.zoom, maskData: $0.maskData)
        }
        let trajectory = try modelContext.fetch(
            FetchDescriptor<TrajectoryChunkRecord>(sortBy: [SortDescriptor(\.sequence)])
        ).map {
            BackupTrajectoryChunk(
                id: $0.id,
                tripID: $0.tripID,
                sequence: $0.sequence,
                points: $0.points.map(BackupHistoryPoint.init)
            )
        }
        var trajectoryBounds: [UUID: (first: Date, last: Date)] = [:]
        for chunk in trajectory {
            for point in chunk.points {
                let date = Date(timeIntervalSince1970: TimeInterval(point.timestampSeconds))
                if let bounds = trajectoryBounds[chunk.tripID] {
                    trajectoryBounds[chunk.tripID] = (min(bounds.first, date), max(bounds.last, date))
                } else {
                    trajectoryBounds[chunk.tripID] = (date, date)
                }
            }
        }
        let trips = try modelContext.fetch(
            FetchDescriptor<HistoryTripRecord>(sortBy: [SortDescriptor(\.startedAt)])
        ).map { trip -> BackupTrip in
            let bounds = trajectoryBounds[trip.id]
            let startedAt = min(trip.startedAt, bounds?.first ?? trip.startedAt)
            let endedAt = trip.endedAt.map { max(max($0, startedAt), bounds?.last ?? $0) }
            let elapsedDuration = endedAt.map {
                max(trip.elapsedDuration, $0.timeIntervalSince(startedAt))
            } ?? trip.elapsedDuration
            return BackupTrip(
                id: trip.id,
                startedAt: startedAt,
                endedAt: endedAt,
                startTimeZoneIdentifier: trip.startTimeZoneIdentifier,
                endTimeZoneIdentifier: trip.endTimeZoneIdentifier,
                originPlaceID: trip.originPlaceID,
                destinationPlaceID: trip.destinationPlaceID,
                distanceMeters: trip.distanceMeters,
                movingDuration: trip.movingDuration,
                elapsedDuration: elapsedDuration,
                averageMovingSpeedMetersPerSecond: trip.averageMovingSpeedMetersPerSecond,
                peakSpeedMetersPerSecond: trip.peakSpeedMetersPerSecond,
                modeRawValue: trip.modeRawValue,
                modeConfidence: trip.modeConfidence,
                completeness: trip.completeness,
                isExcluded: trip.isExcluded,
                routePatternID: trip.routePatternID
            )
        }
        let visits = try modelContext.fetch(
            FetchDescriptor<HistoryVisitRecord>(sortBy: [SortDescriptor(\.arrivalDate)])
        ).map { visit in
            let departureDate = visit.departureDate.map { max($0, visit.arrivalDate) }
            return BackupVisit(
                id: visit.id,
                placeID: visit.placeID,
                arrivalDate: visit.arrivalDate,
                departureDate: departureDate,
                timeZoneIdentifier: visit.timeZoneIdentifier,
                latitude: visit.latitude,
                longitude: visit.longitude,
                radiusMeters: visit.radiusMeters,
                sourceRawValue: visit.sourceRawValue,
                quality: visit.quality,
                isExcluded: visit.isExcluded
            )
        }
        let places = try modelContext.fetch(FetchDescriptor<HistoryPlaceRecord>()).map {
            BackupPlace(
                id: $0.id,
                latitude: $0.latitude,
                longitude: $0.longitude,
                radiusMeters: $0.radiusMeters,
                name: $0.name,
                category: $0.category,
                labelSourceRawValue: $0.labelSourceRawValue,
                isFavorite: $0.isFavorite,
                isExcluded: $0.isExcluded
            )
        }
        let routes = try modelContext.fetch(FetchDescriptor<HistoryRoutePatternRecord>()).map {
            BackupRoute(
                id: $0.id,
                originPlaceID: $0.originPlaceID,
                destinationPlaceID: $0.destinationPlaceID,
                name: $0.name,
                representativePoints: (try HistoryPointCodec.decode($0.representativeGeometry)).map(BackupHistoryPoint.init),
                isFavorite: $0.isFavorite,
                isExcluded: $0.isExcluded,
                isManuallyEdited: $0.isManuallyEdited
            )
        }
        let gaps = try modelContext.fetch(FetchDescriptor<HistoryGapRecord>()).map { gap in
            let endedAt = gap.endedAt.map { max($0, gap.startedAt) }
            return BackupGap(
                id: gap.id,
                startedAt: gap.startedAt,
                endedAt: endedAt,
                reasonRawValue: gap.reasonRawValue,
                diagnosisRawValue: gap.diagnosisRawValue,
                resolutionRawValue: gap.resolutionRawValue,
                resolvedAt: gap.resolvedAt,
                travelModeRawValue: gap.travelModeRawValue,
                estimatedDistanceMeters: gap.estimatedDistanceMeters,
                estimatedTravelTime: gap.estimatedTravelTime,
                estimatedRoute: gap.estimatedRoute.map(BackupGapCoordinate.init)
            )
        }
        let preferences = try modelContext.fetch(FetchDescriptor<PlaceSuggestionPreferenceRecord>()).map {
            BackupSuggestionPreference(
                placeID: $0.placeID,
                dismissedSuggestionRawValue: $0.dismissedSuggestionRawValue
            )
        }
        let openTripIDs = Set<UUID>(trips.filter { $0.endedAt == nil }.map(\.id))
        let latestOpenTrajectoryDate = trajectory
            .filter { openTripIDs.contains($0.tripID) }
            .flatMap(\.points)
            .map { Date(timeIntervalSince1970: TimeInterval($0.timestampSeconds)) }
            .max()
        var snapshotDates = [exportedAt]
        if let latestOpenTrajectoryDate { snapshotDates.append(latestOpenTrajectoryDate) }
        snapshotDates.append(contentsOf: trips.filter { $0.endedAt == nil }.map(\.startedAt))
        snapshotDates.append(contentsOf: visits.filter { $0.departureDate == nil }.map(\.arrivalDate))
        snapshotDates.append(contentsOf: gaps.filter { $0.endedAt == nil }.map(\.startedAt))
        let snapshotDate = snapshotDates.max() ?? exportedAt
        return try BackupArchiveCodec.encode(
            LockiBackupEnvelope(
                exportedAt: snapshotDate,
                payload: LockiBackupPayload(
                    coverage: coverage,
                    trajectory: trajectory,
                    trips: trips,
                    visits: visits,
                    places: places,
                    routes: routes,
                    gaps: gaps,
                    suggestionPreferences: preferences
                )
            )
        )
    }

    func importData(_ data: Data) throws -> BackupImportResult {
        let envelope = try BackupArchiveCodec.decode(data)
        do {
            var importResult: BackupImportResult?
            try modelContext.transaction {
                importResult = try merge(envelope)
                try rebuildDerivedData(
                    referenceDate: envelope.exportedAt,
                    coverageChangedAt: (importResult?.mergedCoverageCells ?? 0) > 0
                        ? envelope.exportedAt : nil
                )
                try modelContext.save()
            }
            guard let importResult else { throw BackupArchiveError.invalidValue }
            return importResult
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func merge(_ envelope: LockiBackupEnvelope) throws -> BackupImportResult {
        let payload = envelope.payload
        var insertedPlaces = 0
        var insertedTrips = 0
        var insertedVisits = 0
        var insertedRoutes = 0
        var insertedGaps = 0
        var insertedTrajectory = 0
        var mergedCoverageCells = 0

        var coverageByKey = Dictionary(
            uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<CoverageChunkRecord>()).map { ($0.key, $0) }
        )
        for chunk in payload.coverage {
            let key = CoverageChunkKey(x: chunk.x, y: chunk.y, zoom: chunk.zoom)
            let mask = CoverageMask(data: chunk.maskData)
            if let existing = coverageByKey[key.rawValue] {
                mergedCoverageCells += existing.merge(mask)
            } else {
                let record = CoverageChunkRecord(
                    snapshot: CoverageChunkSnapshot(key: key, mask: mask, revision: 1)
                )
                modelContext.insert(record)
                coverageByKey[key.rawValue] = record
                mergedCoverageCells += mask.setBitCount
            }
        }

        var placesByID = Dictionary(
            uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<HistoryPlaceRecord>()).map { ($0.id, $0) }
        )
        for place in payload.places where placesByID[place.id] == nil {
            let record = HistoryPlaceRecord(
                id: place.id,
                latitude: place.latitude,
                longitude: place.longitude,
                radiusMeters: place.radiusMeters,
                name: place.name,
                labelSourceRawValue: place.labelSourceRawValue
            )
            record.category = place.category
            record.isFavorite = place.isFavorite
            record.isExcluded = place.isExcluded
            modelContext.insert(record)
            placesByID[place.id] = record
            insertedPlaces += 1
        }

        var routesByID = Dictionary(
            uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<HistoryRoutePatternRecord>()).map { ($0.id, $0) }
        )
        for route in payload.routes where routesByID[route.id] == nil {
            let record = HistoryRoutePatternRecord(
                id: route.id,
                originPlaceID: route.originPlaceID,
                destinationPlaceID: route.destinationPlaceID,
                representativeGeometry: try HistoryPointCodec.encode(route.representativePoints.map(\.historyPoint)),
                lastUsedAt: envelope.exportedAt
            )
            record.name = route.name
            record.isFavorite = route.isFavorite
            record.isExcluded = route.isExcluded
            record.isManuallyEdited = route.isManuallyEdited
            modelContext.insert(record)
            routesByID[route.id] = record
            insertedRoutes += 1
        }

        var tripsByID = Dictionary(
            uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<HistoryTripRecord>()).map { ($0.id, $0) }
        )
        for trip in payload.trips where tripsByID[trip.id] == nil {
            let record = HistoryTripRecord(
                id: trip.id,
                startedAt: trip.startedAt,
                startTimeZoneIdentifier: trip.startTimeZoneIdentifier,
                originPlaceID: trip.originPlaceID
            )
            record.endedAt = trip.endedAt ?? max(trip.startedAt, envelope.exportedAt)
            record.endTimeZoneIdentifier = trip.endTimeZoneIdentifier ?? trip.startTimeZoneIdentifier
            record.destinationPlaceID = trip.destinationPlaceID
            record.distanceMeters = trip.distanceMeters
            record.movingDuration = trip.movingDuration
            record.elapsedDuration = trip.elapsedDuration
            record.averageMovingSpeedMetersPerSecond = trip.averageMovingSpeedMetersPerSecond
            record.peakSpeedMetersPerSecond = trip.peakSpeedMetersPerSecond
            record.modeRawValue = trip.modeRawValue
            record.modeConfidence = trip.modeConfidence
            record.completeness = trip.completeness
            record.isExcluded = trip.isExcluded
            record.routePatternID = trip.routePatternID
            modelContext.insert(record)
            tripsByID[trip.id] = record
            insertedTrips += 1
        }

        var visitsByID = Dictionary(
            uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<HistoryVisitRecord>()).map { ($0.id, $0) }
        )
        for visit in payload.visits where visitsByID[visit.id] == nil {
            let record = HistoryVisitRecord(
                id: visit.id,
                placeID: visit.placeID,
                arrivalDate: visit.arrivalDate,
                departureDate: visit.departureDate ?? max(visit.arrivalDate, envelope.exportedAt),
                timeZoneIdentifier: visit.timeZoneIdentifier,
                latitude: visit.latitude,
                longitude: visit.longitude,
                radiusMeters: visit.radiusMeters,
                sourceRawValue: visit.sourceRawValue,
                quality: visit.quality
            )
            record.isExcluded = visit.isExcluded
            modelContext.insert(record)
            visitsByID[visit.id] = record
            insertedVisits += 1
        }

        var trajectoryIDs = Set(try modelContext.fetch(FetchDescriptor<TrajectoryChunkRecord>()).map(\.id))
        for chunk in payload.trajectory where !trajectoryIDs.contains(chunk.id) {
            let record = try TrajectoryChunkRecord(
                id: chunk.id,
                tripID: chunk.tripID,
                sequence: chunk.sequence,
                points: chunk.points.map(\.historyPoint)
            )
            modelContext.insert(record)
            trajectoryIDs.insert(chunk.id)
            insertedTrajectory += 1
        }

        var gapIDs = Set(try modelContext.fetch(FetchDescriptor<HistoryGapRecord>()).map(\.id))
        for gap in payload.gaps where !gapIDs.contains(gap.id) {
            let reason = HistoryGapReason(rawValue: gap.reasonRawValue) ?? .unavailable
            let record = HistoryGapRecord(
                id: gap.id,
                startedAt: gap.startedAt,
                endedAt: gap.endedAt ?? max(gap.startedAt, envelope.exportedAt),
                reason: reason,
                diagnosis: gap.diagnosisRawValue.flatMap(HistoryGapDiagnosis.init(rawValue:))
            )
            record.resolutionRawValue = gap.resolutionRawValue ?? HistoryGapResolution.unresolved.rawValue
            record.resolvedAt = gap.resolvedAt
            record.travelModeRawValue = gap.travelModeRawValue
            record.estimatedDistanceMeters = gap.estimatedDistanceMeters
            record.estimatedTravelTime = gap.estimatedTravelTime
            if let route = gap.estimatedRoute, !route.isEmpty {
                record.estimatedRouteData = try HistoryGapRouteCodec.encode(route.map(\.coordinate))
            }
            modelContext.insert(record)
            gapIDs.insert(gap.id)
            insertedGaps += 1
        }

        var preferencePlaceIDs = Set(
            try modelContext.fetch(FetchDescriptor<PlaceSuggestionPreferenceRecord>()).map(\.placeID)
        )
        for preference in payload.suggestionPreferences where !preferencePlaceIDs.contains(preference.placeID) {
            modelContext.insert(
                PlaceSuggestionPreferenceRecord(
                    placeID: preference.placeID,
                    dismissedSuggestionRawValue: preference.dismissedSuggestionRawValue
                )
            )
            preferencePlaceIDs.insert(preference.placeID)
        }

        return BackupImportResult(
            insertedPlaces: insertedPlaces,
            insertedTrips: insertedTrips,
            insertedVisits: insertedVisits,
            insertedRoutes: insertedRoutes,
            insertedGaps: insertedGaps,
            insertedTrajectoryChunks: insertedTrajectory,
            mergedCoverageCells: mergedCoverageCells
        )
    }

    private func rebuildDerivedData(referenceDate: Date, coverageChangedAt: Date?) throws {
        let trips = try modelContext.fetch(FetchDescriptor<HistoryTripRecord>())
        let visits = try modelContext.fetch(FetchDescriptor<HistoryVisitRecord>())
        let gaps = try modelContext.fetch(FetchDescriptor<HistoryGapRecord>())
        let trajectory = try modelContext.fetch(FetchDescriptor<TrajectoryChunkRecord>())

        let metadata = try fetchOrCreateMetadata()
        metadata.encodedByteCount = trajectory.reduce(0) { $0 + $1.encodedPoints.count }
        let latestDate = (
            trips.compactMap { $0.endedAt ?? $0.startedAt }
                + visits.map { $0.departureDate ?? $0.arrivalDate }
                + gaps.map { $0.endedAt ?? $0.startedAt }
        ).max()
        if let latestDate {
            metadata.lastProcessedAt = max(metadata.lastProcessedAt ?? .distantPast, latestDate)
        }
        let effectiveReferenceDate = max(referenceDate, metadata.lastProcessedAt ?? referenceDate, Date.now)

        for place in try modelContext.fetch(FetchDescriptor<HistoryPlaceRecord>()) {
            let placeVisits = visits.filter { $0.placeID == place.id && !$0.isExcluded }
            place.visitCount = placeVisits.count
            place.totalDuration = placeVisits.reduce(0) {
                $0 + max(($1.departureDate ?? effectiveReferenceDate).timeIntervalSince($1.arrivalDate), 0)
            }
            place.firstVisitAt = placeVisits.map(\.arrivalDate).min()
            place.lastVisitAt = placeVisits.map { $0.departureDate ?? $0.arrivalDate }.max()
            place.distinctDayCount = Set(placeVisits.map { Calendar.current.startOfDay(for: $0.arrivalDate) }).count
        }

        for route in try modelContext.fetch(FetchDescriptor<HistoryRoutePatternRecord>()) {
            let routeTrips = trips.filter { $0.routePatternID == route.id }
            route.tripCount = routeTrips.count
            route.distinctDayCount = Set(routeTrips.map { Calendar.current.startOfDay(for: $0.startedAt) }).count
            route.totalDistanceMeters = routeTrips.reduce(0) { $0 + $1.distanceMeters }
            route.totalDuration = routeTrips.reduce(0) { $0 + $1.elapsedDuration }
            route.lastUsedAt = routeTrips.map { $0.endedAt ?? $0.startedAt }.max() ?? route.lastUsedAt
        }

        try modelContext.delete(model: HistoryDailySummaryRecord.self)
        for trip in trips where isMeaningful(trip) {
            let summary = try dailySummary(at: trip.startedAt, timeZoneIdentifier: trip.startTimeZoneIdentifier)
            summary.distanceMeters += trip.distanceMeters
            summary.movingDuration += trip.movingDuration
            summary.tripCount += 1
            summary.peakSpeedMetersPerSecond = max(summary.peakSpeedMetersPerSecond, trip.peakSpeedMetersPerSecond)
        }
        for visit in visits where !visit.isExcluded {
            try addVisit(visit, referenceDate: effectiveReferenceDate)
        }
        for gap in gaps {
            if let end = gap.endedAt, end > gap.startedAt {
                try addGap(from: gap.startedAt, to: end)
            }
        }
        for summary in try modelContext.fetch(FetchDescriptor<HistoryDailySummaryRecord>()) {
            updateCompleteness(summary)
        }

        let coverage = try modelContext.fetch(FetchDescriptor<CoverageChunkRecord>())
        let explorationSummary = try fetchOrCreateExplorationSummary()
        explorationSummary.exploredCellCount = coverage.reduce(0) { $0 + CoverageMask(data: $1.maskData).setBitCount }
        if let coverageChangedAt {
            explorationSummary.lastUnlockDate = max(
                explorationSummary.lastUnlockDate ?? .distantPast,
                coverageChangedAt
            )
        }
    }

    private func dailySummary(at date: Date, timeZoneIdentifier: String) throws -> HistoryDailySummaryRecord {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        let dayStart = calendar.startOfDay(for: date)
        let key = HistoryDailySummaryRecord.key(dayStart: dayStart, timeZoneIdentifier: timeZoneIdentifier)
        if let existing = try modelContext.fetch(FetchDescriptor<HistoryDailySummaryRecord>()).first(where: { $0.key == key }) {
            return existing
        }
        let summary = HistoryDailySummaryRecord(dayStart: dayStart, timeZoneIdentifier: timeZoneIdentifier)
        modelContext.insert(summary)
        return summary
    }

    private func addVisit(_ visit: HistoryVisitRecord, referenceDate: Date) throws {
        let end = min(visit.departureDate ?? referenceDate, referenceDate)
        guard end > visit.arrivalDate else { return }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: visit.timeZoneIdentifier) ?? .current
        var cursor = visit.arrivalDate
        var countedVisit = false
        while cursor < end {
            let dayStart = calendar.startOfDay(for: cursor)
            let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? end
            let segmentEnd = min(end, nextDay)
            let summary = try dailySummary(at: cursor, timeZoneIdentifier: visit.timeZoneIdentifier)
            summary.placeDuration += segmentEnd.timeIntervalSince(cursor)
            if !countedVisit {
                summary.visitCount += 1
                countedVisit = true
            }
            cursor = segmentEnd
        }
    }

    private func addGap(from start: Date, to end: Date) throws {
        let timeZoneIdentifier = TimeZone.current.identifier
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        var cursor = start
        while cursor < end {
            let dayStart = calendar.startOfDay(for: cursor)
            let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? end
            let segmentEnd = min(end, nextDay)
            let summary = try dailySummary(at: cursor, timeZoneIdentifier: timeZoneIdentifier)
            summary.gapDuration += segmentEnd.timeIntervalSince(cursor)
            cursor = segmentEnd
        }
    }

    private func updateCompleteness(_ summary: HistoryDailySummaryRecord) {
        let total = summary.movingDuration + summary.placeDuration + summary.gapDuration
        summary.completeness = total > 0 ? max(0, 1 - summary.gapDuration / total) : 0
    }

    private func isMeaningful(_ trip: HistoryTripRecord) -> Bool {
        !trip.isExcluded
            && (trip.distanceMeters >= HistoryConfiguration.standard.minimumTripDistanceMeters
                || trip.elapsedDuration >= HistoryConfiguration.standard.minimumTripDuration)
    }

    private func fetchOrCreateMetadata() throws -> HistoryMetadataRecord {
        if let existing = try modelContext.fetch(FetchDescriptor<HistoryMetadataRecord>()).first(where: { $0.key == "primary" }) {
            return existing
        }
        let record = HistoryMetadataRecord()
        modelContext.insert(record)
        return record
    }

    private func fetchOrCreateExplorationSummary() throws -> ExplorationSummaryRecord {
        if let existing = try modelContext.fetch(FetchDescriptor<ExplorationSummaryRecord>()).first(where: { $0.key == "primary" }) {
            return existing
        }
        let record = ExplorationSummaryRecord()
        modelContext.insert(record)
        return record
    }
}
