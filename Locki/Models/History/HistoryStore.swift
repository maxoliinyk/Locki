//
//  HistoryStore.swift
//  Locki
//
//  Created by Max Oliinyk on 17.07.2026.
//

import Foundation
import SwiftData

nonisolated enum HistoryStoreError: Error {
    case emptyTrajectory
}

@ModelActor
actor HistoryStore {
    private let configuration = HistoryConfiguration.standard
    private let filter = HistorySampleFilter()
    private let reducer = TrajectoryReducer()
    private let visitEngine = VisitInferenceEngine()
    private let routeEngine = RouteSimilarityEngine()
    private let currentInferenceVersion = 5
    private var latestMotion: MotionActivitySample?
    private var stationarySince: Date?

    func prepare() throws -> HistoryOverview {
        let metadata = try metadata()
        if metadata.inferenceVersion < currentInferenceVersion {
            try repairOrphanedVisits(metadata: metadata)
            try rebuildDailySummaries()
            try rebuildRoutePatterns()
            metadata.inferenceVersion = currentInferenceVersion
        }
        try modelContext.save()
        return try overview()
    }

    func flush() throws {
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func setEnabled(_ enabled: Bool, at date: Date = .now) throws -> HistoryOverview {
        let metadata = try metadata()
        if enabled {
            if metadata.enabledAt == nil {
                metadata.enabledAt = date
                try closeOpenGap(reason: .disabled, at: date)
            }
        } else if metadata.enabledAt != nil {
            metadata.enabledAt = nil
            try addGap(start: date, end: nil, reason: .disabled)
            try closeOpenTrip(metadata: metadata, at: metadata.lastProcessedAt ?? date, completeness: 0.8)
            try closeOpenVisit(metadata: metadata, at: date)
            resetCandidate(metadata)
            clearSegmentContinuity(metadata)
        }
        try modelContext.save()
        return try overview()
    }

    func ingest(_ event: HistoryEvent, now: Date = .now) throws -> HistoryOverview {
        switch event {
        case .sample(let sample):
            try ingest(sample, now: now)
        case .visit(let visit):
            try ingest(visit)
        case .region(let event):
            try ingest(event)
        case .motion(let activity):
            try ingest(activity)
        case .dwellCheck(let date):
            try confirmDwell(at: date)
        case .reconcile(let date, _):
            try confirmDwell(at: date)
        case .gap(let start, let end, let reason):
            let metadata = try metadata()
            try closeOpenVisit(metadata: metadata, at: start)
            try closeOpenTrip(metadata: metadata, at: start, completeness: 0.75)
            resetCandidate(metadata)
            clearSegmentContinuity(metadata)
            try addGap(
                start: start,
                end: end,
                reason: reason,
                diagnosis: defaultDiagnosis(for: reason)
            )
        }
        try modelContext.save()
        return try overview()
    }

    func overview() throws -> HistoryOverview {
        let trips = try modelContext.fetch(FetchDescriptor<HistoryTripRecord>())
        let visits = try modelContext.fetch(FetchDescriptor<HistoryVisitRecord>())
        let places = try modelContext.fetch(FetchDescriptor<HistoryPlaceRecord>())
        let days = try modelContext.fetch(FetchDescriptor<HistoryDailySummaryRecord>())
        let gaps = try modelContext.fetch(FetchDescriptor<HistoryGapRecord>())
            .filter { $0.resolution != .noMovement }
        let metadata = try metadata()
        let referenceNow = metadata.lastProcessedAt ?? .now
        return HistoryOverview(
            distanceMeters: trips.filter { !$0.isExcluded }.reduce(0) { $0 + $1.distanceMeters },
            movingDuration: trips.filter { !$0.isExcluded }.reduce(0) { $0 + $1.movingDuration },
            placeDuration: visits.filter { !$0.isExcluded }.reduce(0) {
                $0 + max(($1.departureDate ?? referenceNow).timeIntervalSince($1.arrivalDate), 0)
            },
            tripCount: trips.filter(isMeaningfulTrip).count,
            visitCount: visits.filter { !$0.isExcluded }.count,
            placeCount: places.filter { !$0.isExcluded }.count,
            trackedDayCount: days.count,
            gapCount: gaps.count,
            encodedByteCount: metadata.encodedByteCount,
            latestEventAt: metadata.lastProcessedAt,
            provisionalStay: try provisionalStay(metadata: metadata)
        )
    }

    func monitoredPlaceCandidates() throws -> [MonitoredPlaceCandidate] {
        let metadata = try metadata()
        var candidates = try modelContext.fetch(FetchDescriptor<HistoryPlaceRecord>())
            .filter { !$0.isExcluded }
            .map {
                MonitoredPlaceCandidate(
                    placeID: $0.id,
                    coordinate: GeoCoordinate(latitude: $0.latitude, longitude: $0.longitude),
                    radiusMeters: $0.radiusMeters,
                    isCandidate: false,
                    isFavorite: $0.isFavorite,
                    isUserNamed: $0.labelSourceRawValue == "user",
                    visitCount: $0.visitCount,
                    totalDuration: $0.totalDuration,
                    lastVisitAt: $0.lastVisitAt
                )
            }
        if metadata.openVisitID == nil,
           let latitude = metadata.candidateLatitude,
           let longitude = metadata.candidateLongitude {
            candidates.append(
                MonitoredPlaceCandidate(
                    placeID: try matchingPlace(
                        coordinate: GeoCoordinate(latitude: latitude, longitude: longitude),
                        accuracy: metadata.candidateAccuracyMeters ?? configuration.baseVisitRadiusMeters
                    )?.id,
                    coordinate: GeoCoordinate(latitude: latitude, longitude: longitude),
                    radiusMeters: metadata.candidateAccuracyMeters ?? configuration.baseVisitRadiusMeters,
                    isCandidate: true,
                    isFavorite: false,
                    isUserNamed: false,
                    visitCount: 0,
                    totalDuration: 0,
                    lastVisitAt: metadata.candidateStartedAt
                )
            )
        }
        return candidates
    }

    func deleteTrip(id: UUID) throws -> HistoryOverview {
        let chunks = try modelContext.fetch(FetchDescriptor<TrajectoryChunkRecord>())
            .filter { $0.tripID == id }
        chunks.forEach(modelContext.delete)
        if let trip = try modelContext.fetch(FetchDescriptor<HistoryTripRecord>()).first(where: { $0.id == id }) {
            modelContext.delete(trip)
        }
        try rebuildRoutePatterns()
        try rebuildSummariesAndPlaces()
        try modelContext.save()
        return try overview()
    }

    func deleteVisit(id: UUID) throws -> HistoryOverview {
        if let visit = try modelContext.fetch(FetchDescriptor<HistoryVisitRecord>()).first(where: { $0.id == id }) {
            let placeID = visit.placeID
            modelContext.delete(visit)
            if let placeID { try refreshPlace(id: placeID) }
        }
        try rebuildDailySummaries()
        try modelContext.save()
        return try overview()
    }

    func gapSnapshot(id: UUID) throws -> HistoryGapSnapshot? {
        guard let gap = try modelContext.fetch(FetchDescriptor<HistoryGapRecord>())
            .first(where: { $0.id == id }) else { return nil }
        let points = try modelContext.fetch(FetchDescriptor<TrajectoryChunkRecord>())
            .flatMap(\.points)
        let startPoint = points
            .filter {
                $0.timestamp <= gap.startedAt.addingTimeInterval(1)
                    && gap.startedAt.timeIntervalSince($0.timestamp) <= 60
            }
            .max { $0.timestamp < $1.timestamp }
        let endPoint = gap.endedAt.flatMap { endedAt in
            points
                .filter {
                    $0.timestamp >= endedAt.addingTimeInterval(-1)
                        && $0.timestamp.timeIntervalSince(endedAt) <= 60
                }
                .min { $0.timestamp < $1.timestamp }
        }
        let start = startPoint.map(HistoryGapEndpoint.init)
        let end = endPoint.map(HistoryGapEndpoint.init)
        let modes = try modelContext.fetch(FetchDescriptor<HistoryTripRecord>())
            .filter { trip in
                abs((trip.endedAt ?? trip.startedAt).timeIntervalSince(gap.startedAt)) <= 60
                    || gap.endedAt.map { gapEnd in
                        abs(trip.startedAt.timeIntervalSince(gapEnd)) <= 60
                    } == true
            }
            .map(\.mode)
        let assessment = HistoryGapAssessmentEngine().assess(
            reason: gap.reason,
            startedAt: gap.startedAt,
            endedAt: gap.endedAt,
            start: start,
            end: end,
            surroundingModes: modes
        )
        return HistoryGapSnapshot(
            id: gap.id,
            startedAt: gap.startedAt,
            endedAt: gap.endedAt,
            reason: gap.reason,
            diagnosis: gap.diagnosis ?? gap.reason.defaultDiagnosis,
            resolution: gap.resolution,
            resolvedAt: gap.resolvedAt,
            travelMode: gap.travelMode,
            estimatedDistanceMeters: gap.estimatedDistanceMeters,
            estimatedTravelTime: gap.estimatedTravelTime,
            estimatedRoute: gap.estimatedRoute,
            assessment: assessment
        )
    }

    func resolveGapRoute(id: UUID, suggestion: GapRouteSuggestion, at date: Date = .now) throws {
        guard let gap = try modelContext.fetch(FetchDescriptor<HistoryGapRecord>())
            .first(where: { $0.id == id }) else { return }
        gap.resolutionRawValue = HistoryGapResolution.confirmedRoute.rawValue
        gap.resolvedAt = date
        gap.travelModeRawValue = suggestion.mode.rawValue
        gap.estimatedDistanceMeters = suggestion.distanceMeters
        gap.estimatedTravelTime = suggestion.expectedTravelTime
        gap.estimatedRouteData = try HistoryGapRouteCodec.encode(suggestion.coordinates)
        try modelContext.save()
    }

    func resolveGapNoMovement(id: UUID, at date: Date = .now) throws {
        guard let gap = try modelContext.fetch(FetchDescriptor<HistoryGapRecord>())
            .first(where: { $0.id == id }) else { return }
        clearGapResolution(gap)
        gap.resolutionRawValue = HistoryGapResolution.noMovement.rawValue
        gap.resolvedAt = date
        try rebuildDailySummaries()
        try modelContext.save()
    }

    func dismissGap(id: UUID, at date: Date = .now) throws {
        guard let gap = try modelContext.fetch(FetchDescriptor<HistoryGapRecord>())
            .first(where: { $0.id == id }) else { return }
        clearGapResolution(gap)
        gap.resolutionRawValue = HistoryGapResolution.dismissed.rawValue
        gap.resolvedAt = date
        try modelContext.save()
    }

    func restoreGap(id: UUID) throws {
        guard let gap = try modelContext.fetch(FetchDescriptor<HistoryGapRecord>())
            .first(where: { $0.id == id }) else { return }
        clearGapResolution(gap)
        try rebuildDailySummaries()
        try modelContext.save()
    }

    func applyGapBatch(
        ids: Set<UUID>,
        action: HistoryGapBatchAction,
        at date: Date = .now
    ) throws -> HistoryGapBatchResult {
        guard !ids.isEmpty else {
            return HistoryGapBatchResult(requestedCount: 0, appliedIDs: [])
        }

        do {
            var appliedIDs = Set<UUID>()
            try modelContext.transaction {
                let gaps = try modelContext.fetch(FetchDescriptor<HistoryGapRecord>())
                    .filter { ids.contains($0.id) }
                for gap in gaps where canApply(action, to: gap) {
                    clearGapResolution(gap)
                    switch action {
                    case .noMovement:
                        gap.resolutionRawValue = HistoryGapResolution.noMovement.rawValue
                        gap.resolvedAt = date
                    case .dismiss:
                        gap.resolutionRawValue = HistoryGapResolution.dismissed.rawValue
                        gap.resolvedAt = date
                    case .restore:
                        break
                    }
                    appliedIDs.insert(gap.id)
                }
                if !appliedIDs.isEmpty {
                    if action == .noMovement || action == .restore {
                        try rebuildDailySummaries()
                    }
                    try modelContext.save()
                }
            }
            return HistoryGapBatchResult(requestedCount: ids.count, appliedIDs: appliedIDs)
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func deleteHistory(from start: Date? = nil, to end: Date? = nil) throws -> HistoryOverview {
        let lower = start ?? .distantPast
        let upper = end ?? .distantFuture
        let metadata = try metadata()
        var deletedTripIDs = Set<UUID>()
        var deletedVisitIDs = Set<UUID>()
        for trip in try modelContext.fetch(FetchDescriptor<HistoryTripRecord>())
        where trip.startedAt < upper && (trip.endedAt ?? .distantFuture) >= lower {
            deletedTripIDs.insert(trip.id)
            let points = try chunks(for: trip.id).flatMap(\.points)
            let before = points.filter { $0.timestamp < lower }
            let after = points.filter { $0.timestamp >= upper }
            let wasOpen = trip.endedAt == nil
            let origin = trip.originPlaceID
            let destination = trip.destinationPlaceID
            try deleteTripRecords(id: trip.id)
            if !before.isEmpty {
                try insertTrimmedTrip(
                    points: before,
                    originPlaceID: origin,
                    destinationPlaceID: nil,
                    isOpen: false
                )
            }
            if !after.isEmpty {
                let replacement = try insertTrimmedTrip(
                    points: after,
                    originPlaceID: nil,
                    destinationPlaceID: destination,
                    isOpen: wasOpen
                )
                if wasOpen { metadata.openTripID = replacement.id }
            }
        }
        for visit in try modelContext.fetch(FetchDescriptor<HistoryVisitRecord>())
        where visit.arrivalDate < upper && (visit.departureDate ?? .distantFuture) >= lower {
            let departure = visit.departureDate ?? .distantFuture
            if visit.arrivalDate < lower, departure > upper {
                let wasOpen = visit.departureDate == nil
                let right = HistoryVisitRecord(
                    placeID: visit.placeID,
                    arrivalDate: upper,
                    departureDate: visit.departureDate,
                    timeZoneIdentifier: visit.timeZoneIdentifier,
                    latitude: visit.latitude,
                    longitude: visit.longitude,
                    radiusMeters: visit.radiusMeters,
                    sourceRawValue: visit.sourceRawValue,
                    quality: visit.quality
                )
                right.isExcluded = visit.isExcluded
                modelContext.insert(right)
                visit.departureDate = lower
                if wasOpen { metadata.openVisitID = right.id }
            } else if visit.arrivalDate < lower {
                visit.departureDate = lower
            } else if departure > upper {
                visit.arrivalDate = upper
            } else {
                deletedVisitIDs.insert(visit.id)
                modelContext.delete(visit)
            }
        }
        for gap in try modelContext.fetch(FetchDescriptor<HistoryGapRecord>())
        where gap.startedAt < upper && (gap.endedAt ?? .distantFuture) >= lower {
            let gapEnd = gap.endedAt ?? .distantFuture
            if gap.startedAt < lower, gapEnd > upper {
                modelContext.insert(
                    HistoryGapRecord(
                        startedAt: upper,
                        endedAt: gap.endedAt,
                        reason: gap.reason,
                        diagnosis: gap.diagnosis
                    )
                )
                gap.endedAt = lower
                clearGapResolution(gap)
            } else if gap.startedAt < lower {
                gap.endedAt = lower
                clearGapResolution(gap)
            } else if gapEnd > upper {
                gap.startedAt = upper
                clearGapResolution(gap)
            } else {
                modelContext.delete(gap)
            }
        }
        if let id = metadata.openTripID, deletedTripIDs.contains(id) { metadata.openTripID = nil }
        if let id = metadata.openVisitID, deletedVisitIDs.contains(id) { metadata.openVisitID = nil }
        try rebuildRoutePatterns()
        try rebuildSummariesAndPlaces()
        try modelContext.save()
        return try overview()
    }

    func deleteAll() throws -> HistoryOverview {
        try modelContext.delete(model: TrajectoryChunkRecord.self)
        try modelContext.delete(model: HistoryTripRecord.self)
        try modelContext.delete(model: HistoryVisitRecord.self)
        try modelContext.delete(model: HistoryPlaceRecord.self)
        try modelContext.delete(model: HistoryRoutePatternRecord.self)
        try modelContext.delete(model: HistoryDailySummaryRecord.self)
        try modelContext.delete(model: HistoryGapRecord.self)
        try modelContext.delete(model: PlaceSuggestionPreferenceRecord.self)
        try modelContext.delete(model: HistoryMetadataRecord.self)
        _ = try metadata()
        try modelContext.save()
        return try overview()
    }

    func setFavorite(placeID: UUID, isFavorite: Bool) throws {
        guard let place = try place(id: placeID) else { return }
        place.isFavorite = isFavorite
        try modelContext.save()
    }

    func setFavorite(routeID: UUID, isFavorite: Bool) throws {
        guard let route = try modelContext.fetch(FetchDescriptor<HistoryRoutePatternRecord>())
            .first(where: { $0.id == routeID }) else { return }
        route.isFavorite = isFavorite
        try modelContext.save()
    }

    func updateRoute(id: UUID, name: String?, isExcluded: Bool) throws {
        guard let route = try modelContext.fetch(FetchDescriptor<HistoryRoutePatternRecord>())
            .first(where: { $0.id == id }) else { return }
        let normalizedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        route.name = normalizedName?.isEmpty == false ? normalizedName : nil
        route.isExcluded = isExcluded
        try modelContext.save()
    }

    func mergeRoutes(sourceID: UUID, destinationID: UUID) throws {
        guard sourceID != destinationID else { return }
        let patterns = try modelContext.fetch(FetchDescriptor<HistoryRoutePatternRecord>())
        guard let source = patterns.first(where: { $0.id == sourceID }),
              let destination = patterns.first(where: { $0.id == destinationID }) else { return }
        for trip in try modelContext.fetch(FetchDescriptor<HistoryTripRecord>())
        where trip.routePatternID == sourceID {
            trip.routePatternID = destinationID
        }
        destination.isManuallyEdited = true
        modelContext.delete(source)
        try refreshRoute(id: destinationID)
        try modelContext.save()
    }

    func splitTripFromRoute(tripID: UUID) throws {
        guard let trip = try modelContext.fetch(FetchDescriptor<HistoryTripRecord>())
            .first(where: { $0.id == tripID }),
              let oldPatternID = trip.routePatternID,
              let origin = trip.originPlaceID,
              let destination = trip.destinationPlaceID else { return }
        let points = try chunks(for: trip.id).flatMap(\.points)
        guard points.count >= 2 else { return }
        let pattern = HistoryRoutePatternRecord(
            originPlaceID: origin,
            destinationPlaceID: destination,
            representativeGeometry: try HistoryPointCodec.encode(points),
            lastUsedAt: trip.endedAt ?? trip.startedAt
        )
        pattern.name = "Separate route"
        pattern.isManuallyEdited = true
        modelContext.insert(pattern)
        trip.routePatternID = pattern.id
        try refreshRoute(id: pattern.id)
        try refreshRoute(id: oldPatternID)
        try modelContext.save()
    }

    func updatePlace(id: UUID, name: String, category: String?, source: String = "user") throws {
        guard let place = try place(id: id) else { return }
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedName.isEmpty { place.name = normalizedName }
        place.category = category?.trimmingCharacters(in: .whitespacesAndNewlines)
        place.labelSourceRawValue = source
        for preference in try modelContext.fetch(FetchDescriptor<PlaceSuggestionPreferenceRecord>())
        where preference.placeID == id {
            modelContext.delete(preference)
        }
        try modelContext.save()
    }

    func mergePlaces(sourceID: UUID, destinationID: UUID) throws {
        guard sourceID != destinationID,
              let source = try place(id: sourceID),
              try place(id: destinationID) != nil else { return }
        for visit in try modelContext.fetch(FetchDescriptor<HistoryVisitRecord>()) where visit.placeID == sourceID {
            visit.placeID = destinationID
        }
        for trip in try modelContext.fetch(FetchDescriptor<HistoryTripRecord>()) {
            if trip.originPlaceID == sourceID { trip.originPlaceID = destinationID }
            if trip.destinationPlaceID == sourceID { trip.destinationPlaceID = destinationID }
        }
        for preference in try modelContext.fetch(FetchDescriptor<PlaceSuggestionPreferenceRecord>())
        where preference.placeID == sourceID {
            modelContext.delete(preference)
        }
        modelContext.delete(source)
        try refreshPlace(id: destinationID)
        try rebuildRoutePatterns()
        try modelContext.save()
    }

    func splitVisit(id: UUID) throws {
        guard let visit = try modelContext.fetch(FetchDescriptor<HistoryVisitRecord>())
            .first(where: { $0.id == id }) else { return }
        let oldPlaceID = visit.placeID
        let newPlace = createPlace(
            coordinate: GeoCoordinate(latitude: visit.latitude, longitude: visit.longitude),
            radius: visit.radiusMeters
        )
        visit.placeID = newPlace.id
        try refreshPlace(id: newPlace.id)
        if let oldPlaceID { try refreshPlace(id: oldPlaceID) }
        try modelContext.save()
    }

    func setPlaceExcluded(id: UUID, isExcluded: Bool) throws {
        guard let place = try place(id: id) else { return }
        place.isExcluded = isExcluded
        try modelContext.save()
    }

    func dismissLabelSuggestion(id: UUID, suggestion: PlaceLabelSuggestion) throws {
        guard try place(id: id) != nil else { return }
        let preferences = try modelContext.fetch(FetchDescriptor<PlaceSuggestionPreferenceRecord>())
        if let existing = preferences.first(where: { $0.placeID == id }) {
            existing.dismissedSuggestionRawValue = suggestion.rawValue
        } else {
            modelContext.insert(
                PlaceSuggestionPreferenceRecord(
                    placeID: id,
                    dismissedSuggestionRawValue: suggestion.rawValue
                )
            )
        }
        try modelContext.save()
    }

    func exportJSON() throws -> Data {
        let export = try historyExport()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(export)
    }

    func exportGPX() throws -> Data {
        let export = try historyExport()
        var lines = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<gpx version=\"1.1\" creator=\"Locki\" xmlns=\"http://www.topografix.com/GPX/1/1\">",
        ]
        let formatter = ISO8601DateFormatter()
        for place in export.places {
            lines.append("<wpt lat=\"\(place.latitude)\" lon=\"\(place.longitude)\"><name>\(xmlEscaped(place.name))</name></wpt>")
        }
        for trip in export.trips {
            lines.append("<trk><name>Trip \(formatter.string(from: trip.startedAt))</name><trkseg>")
            for point in trip.points {
                lines.append("<trkpt lat=\"\(point.coordinate.latitude)\" lon=\"\(point.coordinate.longitude)\"><time>\(formatter.string(from: point.timestamp))</time></trkpt>")
            }
            lines.append("</trkseg></trk>")
        }
        for gap in export.gaps where gap.resolution == .confirmedRoute && gap.estimatedRoute.count >= 2 {
            lines.append("<trk><name>Estimated route</name><type>estimated</type><trkseg>")
            for coordinate in gap.estimatedRoute {
                lines.append("<trkpt lat=\"\(coordinate.latitude)\" lon=\"\(coordinate.longitude)\"></trkpt>")
            }
            lines.append("</trkseg></trk>")
        }
        lines.append("</gpx>")
        return Data(lines.joined(separator: "\n").utf8)
    }

    private func ingest(_ sample: HistoryLocationSample, now: Date) throws {
        let metadata = try metadata()
        guard let enabledAt = metadata.enabledAt,
              sample.timestamp >= enabledAt,
              filter.accepts(sample, now: now) else { return }

        if let lastDate = metadata.lastProcessedAt, sample.timestamp <= lastDate {
            try ingestLate(sample)
            return
        }

        var segmentPrevious = lastPoint(from: metadata)
        let effectiveSample = sampleWithInferredSpeed(sample, previous: segmentPrevious)
        let point = HistoryPoint(sample: effectiveSample)
        if let previous = segmentPrevious,
           let diagnosis = filter.discontinuityDiagnosis(from: previous, to: point) {
            try closeOpenTrip(metadata: metadata, at: previous.timestamp, completeness: 0.75)
            try addGap(
                start: previous.timestamp,
                end: point.timestamp,
                reason: .discontinuity,
                diagnosis: diagnosis
            )
            segmentPrevious = nil
        }

        let isDwelling = try updateVisitState(sample: effectiveSample, metadata: metadata)
        if !isDwelling, reducer.shouldRetain(effectiveSample, after: segmentPrevious) {
            try append(point: point, previous: segmentPrevious, metadata: metadata)
        }

        metadata.lastProcessedAt = sample.timestamp
        metadata.lastLatitude = sample.coordinate.latitude
        metadata.lastLongitude = sample.coordinate.longitude
        metadata.lastAccuracyMeters = sample.horizontalAccuracyMeters
        metadata.lastSpeedMetersPerSecond = effectiveSample.speedMetersPerSecond
        metadata.lastCourseDegrees = sample.courseDegrees
        metadata.lastTimeZoneIdentifier = sample.timeZoneIdentifier
    }

    private func ingest(_ systemVisit: SystemVisitSample) throws {
        let metadata = try metadata()
        guard let enabledAt = metadata.enabledAt,
              systemVisit.arrivalDate >= enabledAt,
              systemVisit.coordinate.isValid,
              (0...250).contains(systemVisit.horizontalAccuracyMeters) else { return }
        let place = try matchingPlace(
            coordinate: systemVisit.coordinate,
            accuracy: systemVisit.horizontalAccuracyMeters
        ) ?? createPlace(
            coordinate: systemVisit.coordinate,
            radius: visitEngine.radius(forAccuracy: systemVisit.horizontalAccuracyMeters)
        )
        let visit: HistoryVisitRecord
        if let existing = try modelContext.fetch(FetchDescriptor<HistoryVisitRecord>()).first(where: {
            $0.placeID == place.id && abs($0.arrivalDate.timeIntervalSince(systemVisit.arrivalDate)) < 120
        }) {
            if let departure = systemVisit.departureDate { existing.departureDate = departure }
            visit = existing
        } else {
            visit = HistoryVisitRecord(
                placeID: place.id,
                arrivalDate: systemVisit.arrivalDate,
                departureDate: systemVisit.departureDate,
                timeZoneIdentifier: systemVisit.timeZoneIdentifier,
                latitude: systemVisit.coordinate.latitude,
                longitude: systemVisit.coordinate.longitude,
                radiusMeters: visitEngine.radius(forAccuracy: systemVisit.horizontalAccuracyMeters),
                sourceRawValue: "system",
                quality: max(0, 1 - systemVisit.horizontalAccuracyMeters / 250)
            )
            modelContext.insert(visit)
        }
        if systemVisit.departureDate == nil {
            if let openID = metadata.openVisitID, openID != visit.id {
                try closeOpenVisit(metadata: metadata, at: systemVisit.arrivalDate)
            }
            metadata.openVisitID = visit.id
            resetCandidate(metadata)
            try closeOpenTrip(metadata: metadata, at: systemVisit.arrivalDate, destinationPlaceID: place.id)
        } else {
            if metadata.openVisitID == visit.id { metadata.openVisitID = nil }
            metadata.latestPlaceID = place.id
        }
        try refreshPlace(id: place.id)
        try rebuildDailySummaries()
    }

    private func ingest(_ event: PlaceRegionEvent) throws {
        let metadata = try metadata()
        guard metadata.enabledAt != nil, event.coordinate.isValid else { return }

        switch event.state {
        case .inside:
            if let openID = metadata.openVisitID,
               let openVisit = try modelContext.fetch(FetchDescriptor<HistoryVisitRecord>())
                .first(where: { $0.id == openID }),
               event.placeID == openVisit.placeID {
                resetCandidate(metadata)
                return
            }
            metadata.candidateStartedAt = min(metadata.candidateStartedAt ?? event.date, event.date)
            metadata.candidateLatitude = event.coordinate.latitude
            metadata.candidateLongitude = event.coordinate.longitude
            metadata.candidateAccuracyMeters = min(max(event.radiusMeters / 2, 20), 100)
            metadata.candidateCount = max(metadata.candidateCount, 1)
            try confirmDwell(at: event.date)
        case .outside:
            if let openID = metadata.openVisitID,
               let visit = try modelContext.fetch(FetchDescriptor<HistoryVisitRecord>())
                .first(where: { $0.id == openID }),
               event.placeID == nil || event.placeID == visit.placeID {
                try closeOpenVisit(metadata: metadata, at: event.date)
            } else if let latitude = metadata.candidateLatitude,
                      let longitude = metadata.candidateLongitude,
                      GeoCoordinate(latitude: latitude, longitude: longitude)
                        .distance(to: event.coordinate) <= max(event.radiusMeters, 100) {
                resetCandidate(metadata)
            }
        case .unknown:
            break
        }
    }

    private func ingest(_ activity: MotionActivitySample) throws {
        guard activity.confidence >= 1 else { return }
        if let latestMotion, activity.startedAt < latestMotion.startedAt { return }
        latestMotion = activity
        if activity.isReliableStationary {
            stationarySince = stationarySince.map { min($0, activity.startedAt) } ?? activity.startedAt
            try confirmDwell(at: activity.startedAt)
        } else if activity.isReliableMovement {
            stationarySince = nil
            let metadata = try metadata()
            if metadata.openVisitID == nil {
                resetCandidate(metadata)
            } else if metadata.candidateStartedAt == nil {
                metadata.candidateStartedAt = activity.startedAt
            }
        }
    }

    private func ingestLate(_ sample: HistoryLocationSample) throws {
        let point = HistoryPoint(sample: sample)
        let trips = try modelContext.fetch(FetchDescriptor<HistoryTripRecord>())
        let trip = trips.first {
            $0.startedAt <= sample.timestamp && ($0.endedAt ?? .distantFuture) >= sample.timestamp
        } ?? {
            let created = HistoryTripRecord(
                startedAt: sample.timestamp,
                startTimeZoneIdentifier: sample.timeZoneIdentifier
            )
            created.endedAt = sample.timestamp
            created.endTimeZoneIdentifier = sample.timeZoneIdentifier
            modelContext.insert(created)
            return created
        }()
        var points = try chunks(for: trip.id).flatMap(\.points)
        guard !points.contains(where: {
            $0.timestampSeconds == point.timestampSeconds
                && $0.latitudeE5 == point.latitudeE5
                && $0.longitudeE5 == point.longitudeE5
        }) else { return }
        points.append(point)
        points.sort { $0.timestamp < $1.timestamp }
        try replacePoints(points, for: trip)
        try rebuildDailySummaries()
        try rebuildRoutePatterns()
        let metadata = try metadata()
        metadata.encodedByteCount = try modelContext.fetch(FetchDescriptor<TrajectoryChunkRecord>())
            .reduce(0) { $0 + $1.encodedPoints.count }
    }

    private func append(point: HistoryPoint, previous: HistoryPoint?, metadata: HistoryMetadataRecord) throws {
        let trip = try openTrip(metadata: metadata, at: point.timestamp)
        let chunks = try chunks(for: trip.id)
        let oldByteCount: Int
        if let chunk = chunks.last, chunk.pointCount < configuration.pointsPerChunk {
            oldByteCount = chunk.encodedPoints.count
            try chunk.replacePoints(chunk.points + [point])
            metadata.encodedByteCount += chunk.encodedPoints.count - oldByteCount
        } else {
            let chunk = try TrajectoryChunkRecord(
                tripID: trip.id,
                sequence: chunks.count,
                points: [point]
            )
            metadata.encodedByteCount += chunk.encodedPoints.count
            modelContext.insert(chunk)
        }

        guard let previous else { return }
        let duration = point.timestamp.timeIntervalSince(previous.timestamp)
        guard duration > 0, duration <= configuration.tripGapInterval else { return }
        let distance = previous.coordinate.distance(to: point.coordinate)
        trip.distanceMeters += distance
        trip.elapsedDuration = point.timestamp.timeIntervalSince(trip.startedAt)
        let speed = point.speedMetersPerSecond ?? distance / duration
        if speed > 0.5 {
            trip.movingDuration += duration
            trip.averageMovingSpeedMetersPerSecond = trip.distanceMeters / max(trip.movingDuration, 1)
        }
        trip.peakSpeedMetersPerSecond = max(trip.peakSpeedMetersPerSecond, speed)
        try updateDailySummary(point: point, distance: distance, duration: speed > 0.5 ? duration : 0, speed: speed)
    }

    private func updateVisitState(sample: HistoryLocationSample, metadata: HistoryMetadataRecord) throws -> Bool {
        if let openVisitID = metadata.openVisitID,
           let visit = try modelContext.fetch(FetchDescriptor<HistoryVisitRecord>()).first(where: { $0.id == openVisitID }) {
            let center = GeoCoordinate(latitude: visit.latitude, longitude: visit.longitude)
            let activeRadius = min(
                max(visit.radiusMeters, sample.horizontalAccuracyMeters * 2),
                configuration.maximumVisitRadiusMeters
            )
            if sample.coordinate.distance(to: center) <= activeRadius,
               (sample.speedMetersPerSecond ?? 0) <= 1.5 {
                metadata.candidateStartedAt = nil
                return true
            }
            if metadata.candidateStartedAt == nil {
                metadata.candidateStartedAt = sample.timestamp
                return true
            }
            guard let exitStartedAt = metadata.candidateStartedAt,
                  sample.timestamp.timeIntervalSince(exitStartedAt) >= configuration.visitExitDuration else {
                return true
            }
            try closeOpenVisit(metadata: metadata, at: exitStartedAt)
            resetCandidate(metadata)
            return false
        }

        let isStationary = sample.speedMetersPerSecond.map { $0 <= 0.8 }
            ?? (latestMotion?.isReliableStationary == true)
        guard isStationary else {
            resetCandidate(metadata)
            return false
        }

        if let latitude = metadata.candidateLatitude,
           let longitude = metadata.candidateLongitude,
           let startedAt = metadata.candidateStartedAt {
            let center = GeoCoordinate(latitude: latitude, longitude: longitude)
            guard visitEngine.isInsideCandidate(
                sample: sample,
                center: center,
                candidateAccuracy: metadata.candidateAccuracyMeters ?? sample.horizontalAccuracyMeters
            ) else {
                startCandidate(sample, metadata: metadata)
                return false
            }
            let count = max(metadata.candidateCount, 1)
            metadata.candidateLatitude = (latitude * Double(count) + sample.coordinate.latitude) / Double(count + 1)
            metadata.candidateLongitude = (longitude * Double(count) + sample.coordinate.longitude) / Double(count + 1)
            metadata.candidateAccuracyMeters = max(metadata.candidateAccuracyMeters ?? 0, sample.horizontalAccuracyMeters)
            metadata.candidateCount += 1

            guard try candidateQualifies(metadata: metadata, startedAt: startedAt, at: sample.timestamp) else {
                return false
            }
            return try openCandidateVisit(metadata: metadata, fallbackSample: sample)
        }

        startCandidate(sample, metadata: metadata)
        return false
    }

    private func confirmDwell(at date: Date) throws {
        let metadata = try metadata()
        guard metadata.enabledAt != nil,
              metadata.openVisitID == nil,
              let startedAt = metadata.candidateStartedAt,
              date >= startedAt,
              try candidateQualifies(metadata: metadata, startedAt: startedAt, at: date) else { return }
        _ = try openCandidateVisit(metadata: metadata)
    }

    private func candidateQualifies(
        metadata: HistoryMetadataRecord,
        startedAt: Date,
        at date: Date
    ) throws -> Bool {
        guard let latitude = metadata.candidateLatitude,
              let longitude = metadata.candidateLongitude else { return false }
        let coordinate = GeoCoordinate(latitude: latitude, longitude: longitude)
        let knownPlace = try matchingPlace(
            coordinate: coordinate,
            accuracy: metadata.candidateAccuracyMeters ?? configuration.baseVisitRadiusMeters
        )
        let requiredDuration = knownPlace == nil
            ? configuration.minimumVisitDuration
            : configuration.knownPlaceVisitDuration
        guard date.timeIntervalSince(startedAt) >= requiredDuration else { return false }

        let stationaryMotionSupportsCandidate = latestMotion?.isReliableStationary == true
            && (stationarySince ?? latestMotion?.startedAt ?? date) <= date
        let hasCorroboration = metadata.candidateCount >= 2 || stationaryMotionSupportsCandidate
        guard hasCorroboration else { return false }

        if let speed = metadata.lastSpeedMetersPerSecond, speed > 0.8,
           !stationaryMotionSupportsCandidate { return false }
        return true
    }

    private func openCandidateVisit(
        metadata: HistoryMetadataRecord,
        fallbackSample: HistoryLocationSample? = nil
    ) throws -> Bool {
        guard let startedAt = metadata.candidateStartedAt,
              let latitude = metadata.candidateLatitude ?? fallbackSample?.coordinate.latitude,
              let longitude = metadata.candidateLongitude ?? fallbackSample?.coordinate.longitude else { return false }
        let center = GeoCoordinate(latitude: latitude, longitude: longitude)
        let accuracy = metadata.candidateAccuracyMeters
            ?? fallbackSample?.horizontalAccuracyMeters
            ?? configuration.baseVisitRadiusMeters
        let timeZoneIdentifier = fallbackSample?.timeZoneIdentifier
            ?? metadata.lastTimeZoneIdentifier
            ?? TimeZone.current.identifier
        let place = try matchingPlace(coordinate: center, accuracy: accuracy)
            ?? createPlace(coordinate: center, radius: visitEngine.radius(forAccuracy: accuracy))
        let visit = HistoryVisitRecord(
            placeID: place.id,
            arrivalDate: startedAt,
            timeZoneIdentifier: timeZoneIdentifier,
            latitude: center.latitude,
            longitude: center.longitude,
            radiusMeters: visitEngine.radius(forAccuracy: accuracy),
            sourceRawValue: "inferred",
            quality: max(0, 1 - accuracy / configuration.maximumVisitRadiusMeters)
        )
        modelContext.insert(visit)
        metadata.openVisitID = visit.id
        resetCandidate(metadata)
        try refreshPlace(id: place.id)
        let summary = try dailySummary(at: startedAt, timeZoneIdentifier: timeZoneIdentifier)
        summary.visitCount += 1
        try closeOpenTrip(metadata: metadata, at: startedAt, destinationPlaceID: place.id)
        return true
    }

    private func startCandidate(_ sample: HistoryLocationSample, metadata: HistoryMetadataRecord) {
        metadata.candidateStartedAt = sample.timestamp
        metadata.candidateLatitude = sample.coordinate.latitude
        metadata.candidateLongitude = sample.coordinate.longitude
        metadata.candidateAccuracyMeters = sample.horizontalAccuracyMeters
        metadata.candidateCount = 1
    }

    private func resetCandidate(_ metadata: HistoryMetadataRecord) {
        metadata.candidateStartedAt = nil
        metadata.candidateLatitude = nil
        metadata.candidateLongitude = nil
        metadata.candidateAccuracyMeters = nil
        metadata.candidateCount = 0
    }

    private func clearSegmentContinuity(_ metadata: HistoryMetadataRecord) {
        metadata.lastLatitude = nil
        metadata.lastLongitude = nil
        metadata.lastAccuracyMeters = nil
        metadata.lastSpeedMetersPerSecond = nil
        metadata.lastCourseDegrees = nil
    }

    private func sampleWithInferredSpeed(
        _ sample: HistoryLocationSample,
        previous: HistoryPoint?
    ) -> HistoryLocationSample {
        guard sample.speedMetersPerSecond == nil,
              let previous,
              sample.timestamp > previous.timestamp else { return sample }
        let duration = sample.timestamp.timeIntervalSince(previous.timestamp)
        let inferredSpeed = previous.coordinate.distance(to: sample.coordinate) / duration
        guard inferredSpeed.isFinite, inferredSpeed <= configuration.maximumSpeedMetersPerSecond else { return sample }
        return HistoryLocationSample(
            coordinate: sample.coordinate,
            horizontalAccuracyMeters: sample.horizontalAccuracyMeters,
            speedMetersPerSecond: inferredSpeed,
            courseDegrees: sample.courseDegrees,
            timestamp: sample.timestamp,
            timeZoneIdentifier: sample.timeZoneIdentifier,
            hasPreciseAccuracy: sample.hasPreciseAccuracy
        )
    }

    private func closeOpenVisit(metadata: HistoryMetadataRecord, at date: Date) throws {
        guard let id = metadata.openVisitID,
              let visit = try modelContext.fetch(FetchDescriptor<HistoryVisitRecord>())
                .first(where: { $0.id == id }) else {
            metadata.openVisitID = nil
            metadata.candidateStartedAt = nil
            return
        }
        visit.departureDate = max(visit.arrivalDate, date)
        metadata.openVisitID = nil
        metadata.candidateStartedAt = nil
        metadata.latestPlaceID = visit.placeID
        if let placeID = visit.placeID { try refreshPlace(id: placeID) }
        try rebuildDailySummaries()
    }

    private func openTrip(metadata: HistoryMetadataRecord, at date: Date) throws -> HistoryTripRecord {
        if let id = metadata.openTripID,
           let existing = try modelContext.fetch(FetchDescriptor<HistoryTripRecord>()).first(where: { $0.id == id }) {
            return existing
        }
        let trip = HistoryTripRecord(
            startedAt: date,
            startTimeZoneIdentifier: metadata.lastTimeZoneIdentifier ?? TimeZone.current.identifier,
            originPlaceID: metadata.latestPlaceID
        )
        metadata.openTripID = trip.id
        modelContext.insert(trip)
        let summary = try dailySummary(at: date, timeZoneIdentifier: metadata.lastTimeZoneIdentifier ?? TimeZone.current.identifier)
        summary.tripCount += 1
        return trip
    }

    private func closeOpenTrip(
        metadata: HistoryMetadataRecord,
        at date: Date,
        destinationPlaceID: UUID? = nil,
        completeness: Double = 1
    ) throws {
        guard let id = metadata.openTripID,
              let trip = try modelContext.fetch(FetchDescriptor<HistoryTripRecord>()).first(where: { $0.id == id }) else {
            metadata.openTripID = nil
            return
        }
        trip.endedAt = max(date, trip.startedAt)
        trip.endTimeZoneIdentifier = metadata.lastTimeZoneIdentifier
        trip.elapsedDuration = trip.endedAt?.timeIntervalSince(trip.startedAt) ?? 0
        trip.destinationPlaceID = destinationPlaceID
        trip.completeness = min(trip.completeness, completeness)
        let points = try chunks(for: trip.id).flatMap(\.points)
        let speeds = points.compactMap(\.speedMetersPerSecond)
        let classification = reducer.movementMode(for: speeds)
        trip.modeRawValue = classification.mode.rawValue
        trip.modeConfidence = classification.confidence
        trip.peakSpeedMetersPerSecond = reducer.peakSpeed(for: speeds)
        metadata.openTripID = nil
        if trip.distanceMeters < configuration.minimumTripDistanceMeters,
           trip.elapsedDuration < configuration.minimumTripDuration {
            trip.isExcluded = true
            try rebuildDailySummaries()
        } else {
            try assignRoutePattern(to: trip, points: points)
        }
    }

    private func assignRoutePattern(to trip: HistoryTripRecord, points: [HistoryPoint]) throws {
        guard let origin = trip.originPlaceID, let destination = trip.destinationPlaceID else { return }
        let patterns = try modelContext.fetch(FetchDescriptor<HistoryRoutePatternRecord>()).filter {
            Set([$0.originPlaceID, $0.destinationPlaceID]) == Set([origin, destination])
        }
        for pattern in patterns where !pattern.isManuallyEdited {
            let representative = (try? HistoryPointCodec.decode(pattern.representativeGeometry)) ?? []
            if routeEngine.matches(points, representative) {
                trip.routePatternID = pattern.id
                pattern.tripCount += 1
                pattern.totalDistanceMeters += trip.distanceMeters
                pattern.totalDuration += trip.elapsedDuration
                pattern.lastUsedAt = trip.endedAt ?? trip.startedAt
                pattern.distinctDayCount = try distinctDayCount(for: pattern.id, including: trip)
                return
            }
        }
        guard let geometry = try? HistoryPointCodec.encode(points) else { return }
        let pattern = HistoryRoutePatternRecord(
            originPlaceID: origin,
            destinationPlaceID: destination,
            representativeGeometry: geometry,
            lastUsedAt: trip.endedAt ?? trip.startedAt
        )
        pattern.tripCount = 1
        pattern.totalDistanceMeters = trip.distanceMeters
        pattern.totalDuration = trip.elapsedDuration
        pattern.distinctDayCount = 1
        modelContext.insert(pattern)
        trip.routePatternID = pattern.id
    }

    private func matchingPlace(coordinate: GeoCoordinate, accuracy: Double) throws -> HistoryPlaceRecord? {
        let radius = min(max(configuration.baseVisitRadiusMeters, accuracy * 2), configuration.maximumVisitRadiusMeters)
        return try modelContext.fetch(FetchDescriptor<HistoryPlaceRecord>())
            .filter { !$0.isExcluded }
            .min { lhs, rhs in
                coordinate.distance(to: GeoCoordinate(latitude: lhs.latitude, longitude: lhs.longitude))
                    < coordinate.distance(to: GeoCoordinate(latitude: rhs.latitude, longitude: rhs.longitude))
            }
            .flatMap { place in
                coordinate.distance(to: GeoCoordinate(latitude: place.latitude, longitude: place.longitude))
                    <= max(radius, place.radiusMeters) ? place : nil
            }
    }

    private func createPlace(coordinate: GeoCoordinate, radius: Double) -> HistoryPlaceRecord {
        let count = (try? modelContext.fetchCount(FetchDescriptor<HistoryPlaceRecord>())) ?? 0
        let place = HistoryPlaceRecord(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            radiusMeters: radius,
            name: "Place \(count + 1)"
        )
        modelContext.insert(place)
        return place
    }

    private func refreshPlace(id: UUID) throws {
        guard let place = try place(id: id) else { return }
        let referenceNow = try metadata().lastProcessedAt ?? .now
        let visits = try modelContext.fetch(FetchDescriptor<HistoryVisitRecord>()).filter {
            $0.placeID == id && !$0.isExcluded
        }
        guard !visits.isEmpty else {
            for trip in try modelContext.fetch(FetchDescriptor<HistoryTripRecord>()) {
                if trip.originPlaceID == id { trip.originPlaceID = nil }
                if trip.destinationPlaceID == id { trip.destinationPlaceID = nil }
            }
            modelContext.delete(place)
            for preference in try modelContext.fetch(FetchDescriptor<PlaceSuggestionPreferenceRecord>())
            where preference.placeID == id {
                modelContext.delete(preference)
            }
            return
        }
        place.visitCount = visits.count
        place.totalDuration = visits.reduce(0) { result, visit in
            result + max((visit.departureDate ?? referenceNow).timeIntervalSince(visit.arrivalDate), 0)
        }
        place.firstVisitAt = visits.map(\.arrivalDate).min()
        place.lastVisitAt = visits.map { $0.departureDate ?? $0.arrivalDate }.max()
        place.distinctDayCount = Set(visits.map { Calendar.current.startOfDay(for: $0.arrivalDate) }).count
        let weighted = visits.reduce(into: (latitude: 0.0, longitude: 0.0, weight: 0.0)) { result, visit in
            let weight = max(visit.quality, 0.1)
            result.latitude += visit.latitude * weight
            result.longitude += visit.longitude * weight
            result.weight += weight
        }
        if weighted.weight > 0 {
            place.latitude = weighted.latitude / weighted.weight
            place.longitude = weighted.longitude / weighted.weight
        }
        place.radiusMeters = min(
            max(configuration.baseVisitRadiusMeters, visits.map(\.radiusMeters).max() ?? configuration.baseVisitRadiusMeters),
            configuration.maximumVisitRadiusMeters
        )
    }

    private func rebuildSummariesAndPlaces() throws {
        for place in try modelContext.fetch(FetchDescriptor<HistoryPlaceRecord>()) {
            try refreshPlace(id: place.id)
        }
        try rebuildDailySummaries()
        let metadata = try metadata()
        metadata.encodedByteCount = try modelContext.fetch(FetchDescriptor<TrajectoryChunkRecord>())
            .reduce(0) { $0 + $1.encodedPoints.count }
    }

    private func rebuildDailySummaries() throws {
        try modelContext.delete(model: HistoryDailySummaryRecord.self)
        let referenceNow = try metadata().lastProcessedAt ?? .now
        for trip in try modelContext.fetch(FetchDescriptor<HistoryTripRecord>()) where isMeaningfulTrip(trip) {
            let summary = try dailySummary(
                at: trip.startedAt,
                timeZoneIdentifier: trip.startTimeZoneIdentifier
            )
            summary.distanceMeters += trip.distanceMeters
            summary.movingDuration += trip.movingDuration
            summary.tripCount += 1
            summary.peakSpeedMetersPerSecond = max(summary.peakSpeedMetersPerSecond, trip.peakSpeedMetersPerSecond)
        }
        for visit in try modelContext.fetch(FetchDescriptor<HistoryVisitRecord>()) where !visit.isExcluded {
            try addVisitToDailySummaries(visit, now: referenceNow)
        }
        for gap in try modelContext.fetch(FetchDescriptor<HistoryGapRecord>())
        where gap.resolution != .noMovement {
            guard let endedAt = gap.endedAt, endedAt > gap.startedAt else { continue }
            try addGapDuration(from: gap.startedAt, to: endedAt)
        }
        for summary in try modelContext.fetch(FetchDescriptor<HistoryDailySummaryRecord>()) {
            updateCompleteness(summary)
        }
    }

    private func isMeaningfulTrip(_ trip: HistoryTripRecord) -> Bool {
        !trip.isExcluded
            && (trip.distanceMeters >= configuration.minimumTripDistanceMeters
                || trip.elapsedDuration >= configuration.minimumTripDuration)
    }

    private func updateDailySummary(point: HistoryPoint, distance: Double, duration: TimeInterval, speed: Double) throws {
        let summary = try dailySummary(at: point.timestamp, timeZoneIdentifier: point.timeZoneIdentifier)
        summary.distanceMeters += distance
        summary.movingDuration += duration
        summary.peakSpeedMetersPerSecond = max(summary.peakSpeedMetersPerSecond, speed)
        updateCompleteness(summary)
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

    private func addGap(
        start: Date,
        end: Date?,
        reason: HistoryGapReason,
        diagnosis: HistoryGapDiagnosis? = nil
    ) throws {
        guard end == nil || end! > start else { return }
        if let end,
           let open = try modelContext.fetch(FetchDescriptor<HistoryGapRecord>()).first(where: {
               $0.reason == reason && $0.endedAt == nil && abs($0.startedAt.timeIntervalSince(start)) < 1
           }) {
            open.endedAt = end
            open.diagnosisRawValue = open.diagnosisRawValue ?? diagnosis?.rawValue
            try addGapDuration(from: open.startedAt, to: end)
            return
        }
        let duplicate = try modelContext.fetch(FetchDescriptor<HistoryGapRecord>()).contains {
            $0.reason == reason
                && abs($0.startedAt.timeIntervalSince(start)) < 1
                && $0.endedAt == end
        }
        guard !duplicate else { return }
        modelContext.insert(
            HistoryGapRecord(
                startedAt: start,
                endedAt: end,
                reason: reason,
                diagnosis: diagnosis ?? defaultDiagnosis(for: reason)
            )
        )
        if let end {
            try addGapDuration(from: start, to: end)
        }
    }

    private func defaultDiagnosis(for reason: HistoryGapReason) -> HistoryGapDiagnosis {
        switch reason {
        case .authorization: .permissionUnavailable
        case .reducedAccuracy: .preciseLocationUnavailable
        case .discontinuity: .unknownDiscontinuity
        case .disabled: .historyDisabled
        case .persistence: .saveFailed
        case .unavailable: .locationTemporarilyUnavailable
        }
    }

    private func clearGapResolution(_ gap: HistoryGapRecord) {
        gap.resolutionRawValue = HistoryGapResolution.unresolved.rawValue
        gap.resolvedAt = nil
        gap.travelModeRawValue = nil
        gap.estimatedDistanceMeters = nil
        gap.estimatedTravelTime = nil
        gap.estimatedRouteData = nil
    }

    private func canApply(_ action: HistoryGapBatchAction, to gap: HistoryGapRecord) -> Bool {
        switch action {
        case .noMovement:
            gap.reason == .discontinuity && gap.resolution == .unresolved
        case .dismiss:
            gap.resolution == .unresolved
        case .restore:
            gap.resolution != .unresolved
        }
    }

    private func closeOpenGap(reason: HistoryGapReason, at date: Date) throws {
        let openGaps = try modelContext.fetch(FetchDescriptor<HistoryGapRecord>()).filter {
            $0.reason == reason && $0.endedAt == nil && $0.startedAt <= date
        }
        for gap in openGaps {
            guard gap.startedAt < date else {
                modelContext.delete(gap)
                continue
            }
            gap.endedAt = date
            try addGapDuration(from: gap.startedAt, to: date)
        }
    }

    private func addGapDuration(from start: Date, to end: Date) throws {
        guard end > start else { return }
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
            updateCompleteness(summary)
            cursor = segmentEnd
        }
    }

    private func addVisitToDailySummaries(_ visit: HistoryVisitRecord, now: Date = .now) throws {
        let end = min(visit.departureDate ?? now, now)
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

    private func updateCompleteness(_ summary: HistoryDailySummaryRecord) {
        let total = summary.movingDuration + summary.placeDuration + summary.gapDuration
        summary.completeness = total > 0 ? max(0, 1 - summary.gapDuration / total) : 0
    }

    private func metadata() throws -> HistoryMetadataRecord {
        if let record = try modelContext.fetch(FetchDescriptor<HistoryMetadataRecord>()).first(where: { $0.key == "primary" }) {
            return record
        }
        let record = HistoryMetadataRecord()
        modelContext.insert(record)
        return record
    }

    private func provisionalStay(metadata: HistoryMetadataRecord) throws -> ProvisionalStaySnapshot? {
        guard metadata.openVisitID == nil,
              let startedAt = metadata.candidateStartedAt,
              let latitude = metadata.candidateLatitude,
              let longitude = metadata.candidateLongitude else { return nil }
        let matched = try matchingPlace(
            coordinate: GeoCoordinate(latitude: latitude, longitude: longitude),
            accuracy: metadata.candidateAccuracyMeters ?? configuration.baseVisitRadiusMeters
        )
        return ProvisionalStaySnapshot(
            startedAt: startedAt,
            placeID: matched?.id,
            placeName: matched?.name,
            evidenceCount: metadata.candidateCount,
            hasStationaryMotion: latestMotion?.isReliableStationary == true
        )
    }

    private func repairOrphanedVisits(metadata: HistoryMetadataRecord) throws {
        let visits = try modelContext.fetch(FetchDescriptor<HistoryVisitRecord>())
        let openID = metadata.openVisitID
        if let openID, !visits.contains(where: { $0.id == openID && $0.departureDate == nil }) {
            metadata.openVisitID = nil
        }
        for visit in visits where visit.departureDate == nil && visit.id != metadata.openVisitID {
            visit.departureDate = max(visit.arrivalDate, metadata.lastProcessedAt ?? visit.arrivalDate)
            if let placeID = visit.placeID { try refreshPlace(id: placeID) }
        }
    }

    private func place(id: UUID) throws -> HistoryPlaceRecord? {
        try modelContext.fetch(FetchDescriptor<HistoryPlaceRecord>()).first { $0.id == id }
    }

    private func chunks(for tripID: UUID) throws -> [TrajectoryChunkRecord] {
        try modelContext.fetch(
            FetchDescriptor<TrajectoryChunkRecord>(sortBy: [SortDescriptor(\.sequence)])
        ).filter { $0.tripID == tripID }
    }

    private func lastPoint(from metadata: HistoryMetadataRecord) -> HistoryPoint? {
        guard let latitude = metadata.lastLatitude,
              let longitude = metadata.lastLongitude,
              let accuracy = metadata.lastAccuracyMeters,
              let timestamp = metadata.lastProcessedAt else { return nil }
        return HistoryPoint(
            sample: HistoryLocationSample(
                coordinate: GeoCoordinate(latitude: latitude, longitude: longitude),
                horizontalAccuracyMeters: accuracy,
                speedMetersPerSecond: metadata.lastSpeedMetersPerSecond,
                courseDegrees: metadata.lastCourseDegrees,
                timestamp: timestamp,
                timeZoneIdentifier: metadata.lastTimeZoneIdentifier ?? TimeZone.current.identifier
            )
        )
    }

    private func deleteTripRecords(id: UUID) throws {
        for chunk in try chunks(for: id) { modelContext.delete(chunk) }
        if let trip = try modelContext.fetch(FetchDescriptor<HistoryTripRecord>()).first(where: { $0.id == id }) {
            modelContext.delete(trip)
        }
    }

    private func replacePoints(_ points: [HistoryPoint], for trip: HistoryTripRecord) throws {
        for chunk in try chunks(for: trip.id) { modelContext.delete(chunk) }
        for (sequence, startIndex) in stride(
            from: 0,
            to: points.count,
            by: configuration.pointsPerChunk
        ).enumerated() {
            let endIndex = min(startIndex + configuration.pointsPerChunk, points.count)
            modelContext.insert(
                try TrajectoryChunkRecord(
                    tripID: trip.id,
                    sequence: sequence,
                    points: Array(points[startIndex..<endIndex])
                )
            )
        }
        try recalculate(trip: trip, points: points)
    }

    @discardableResult
    private func insertTrimmedTrip(
        points: [HistoryPoint],
        originPlaceID: UUID?,
        destinationPlaceID: UUID?,
        isOpen: Bool
    ) throws -> HistoryTripRecord {
        guard let first = points.first else { throw HistoryStoreError.emptyTrajectory }
        let trip = HistoryTripRecord(
            startedAt: first.timestamp,
            startTimeZoneIdentifier: first.timeZoneIdentifier,
            originPlaceID: originPlaceID
        )
        trip.destinationPlaceID = destinationPlaceID
        trip.endedAt = isOpen ? nil : points.last?.timestamp
        modelContext.insert(trip)
        try replacePoints(points, for: trip)
        if points.count < 2
            || (trip.distanceMeters < configuration.minimumTripDistanceMeters
                && trip.elapsedDuration < configuration.minimumTripDuration) {
            trip.isExcluded = true
        }
        return trip
    }

    private func recalculate(trip: HistoryTripRecord, points: [HistoryPoint]) throws {
        guard let first = points.first, let last = points.last else {
            trip.distanceMeters = 0
            trip.movingDuration = 0
            trip.elapsedDuration = 0
            trip.averageMovingSpeedMetersPerSecond = 0
            trip.peakSpeedMetersPerSecond = 0
            trip.modeRawValue = MovementMode.unknown.rawValue
            trip.modeConfidence = 0
            return
        }
        trip.startedAt = first.timestamp
        trip.endedAt = trip.endedAt == nil ? nil : last.timestamp
        trip.startTimeZoneIdentifier = first.timeZoneIdentifier
        trip.endTimeZoneIdentifier = last.timeZoneIdentifier
        trip.distanceMeters = 0
        trip.movingDuration = 0
        for (previous, current) in zip(points, points.dropFirst())
        where filter.formsPlausibleSegment(from: previous, to: current) {
            let duration = current.timestamp.timeIntervalSince(previous.timestamp)
            let distance = previous.coordinate.distance(to: current.coordinate)
            let speed = current.speedMetersPerSecond ?? distance / duration
            trip.distanceMeters += distance
            if speed > 0.5 { trip.movingDuration += duration }
        }
        trip.elapsedDuration = last.timestamp.timeIntervalSince(first.timestamp)
        trip.averageMovingSpeedMetersPerSecond = trip.distanceMeters / max(trip.movingDuration, 1)
        let speeds = points.compactMap(\.speedMetersPerSecond)
        trip.peakSpeedMetersPerSecond = reducer.peakSpeed(for: speeds)
        let classification = reducer.movementMode(for: speeds)
        trip.modeRawValue = classification.mode.rawValue
        trip.modeConfidence = classification.confidence
    }

    private func rebuildRoutePatterns() throws {
        let trips = try modelContext.fetch(FetchDescriptor<HistoryTripRecord>())
        let patterns = try modelContext.fetch(FetchDescriptor<HistoryRoutePatternRecord>())
        let manualIDs = Set(patterns.filter(\.isManuallyEdited).map(\.id))
        for trip in trips where trip.routePatternID.map({ !manualIDs.contains($0) }) ?? true {
            trip.routePatternID = nil
        }
        for pattern in patterns where !pattern.isManuallyEdited { modelContext.delete(pattern) }
        for id in manualIDs { try refreshRoute(id: id) }
        for trip in trips
        where !trip.isExcluded && trip.endedAt != nil
            && trip.routePatternID == nil
            && trip.originPlaceID != nil && trip.destinationPlaceID != nil {
            try assignRoutePattern(to: trip, points: try chunks(for: trip.id).flatMap(\.points))
        }
    }

    private func distinctDayCount(
        for patternID: UUID,
        including trip: HistoryTripRecord
    ) throws -> Int {
        var dates = try modelContext.fetch(FetchDescriptor<HistoryTripRecord>())
            .filter { $0.routePatternID == patternID }
            .map { Calendar.current.startOfDay(for: $0.startedAt) }
        dates.append(Calendar.current.startOfDay(for: trip.startedAt))
        return Set(dates).count
    }

    private func refreshRoute(id: UUID) throws {
        let patterns = try modelContext.fetch(FetchDescriptor<HistoryRoutePatternRecord>())
        guard let pattern = patterns.first(where: { $0.id == id }) else { return }
        let trips = try modelContext.fetch(FetchDescriptor<HistoryTripRecord>())
            .filter { $0.routePatternID == id }
        guard !trips.isEmpty else {
            modelContext.delete(pattern)
            return
        }
        pattern.tripCount = trips.count
        pattern.distinctDayCount = Set(trips.map { Calendar.current.startOfDay(for: $0.startedAt) }).count
        pattern.totalDistanceMeters = trips.reduce(0) { $0 + $1.distanceMeters }
        pattern.totalDuration = trips.reduce(0) { $0 + $1.elapsedDuration }
        pattern.lastUsedAt = trips.map { $0.endedAt ?? $0.startedAt }.max() ?? pattern.lastUsedAt
    }

    private func historyExport() throws -> HistoryExport {
        let chunks = try modelContext.fetch(
            FetchDescriptor<TrajectoryChunkRecord>(sortBy: [SortDescriptor(\.sequence)])
        )
        let trips = try modelContext.fetch(
            FetchDescriptor<HistoryTripRecord>(sortBy: [SortDescriptor(\.startedAt)])
        ).map { trip in
            ExportedTrip(
                id: trip.id,
                startedAt: trip.startedAt,
                endedAt: trip.endedAt,
                startTimeZoneIdentifier: trip.startTimeZoneIdentifier,
                endTimeZoneIdentifier: trip.endTimeZoneIdentifier,
                distanceMeters: trip.distanceMeters,
                movingDuration: trip.movingDuration,
                mode: trip.mode,
                points: chunks.filter { $0.tripID == trip.id }.flatMap(\.points)
            )
        }
        let visits = try modelContext.fetch(
            FetchDescriptor<HistoryVisitRecord>(sortBy: [SortDescriptor(\.arrivalDate)])
        ).map {
            ExportedVisit(
                id: $0.id,
                placeID: $0.placeID,
                arrivalDate: $0.arrivalDate,
                departureDate: $0.departureDate,
                timeZoneIdentifier: $0.timeZoneIdentifier,
                latitude: $0.latitude,
                longitude: $0.longitude,
                radiusMeters: $0.radiusMeters
            )
        }
        let places = try modelContext.fetch(FetchDescriptor<HistoryPlaceRecord>()).map {
            ExportedPlace(
                id: $0.id,
                name: $0.name,
                category: $0.category,
                latitude: $0.latitude,
                longitude: $0.longitude,
                isFavorite: $0.isFavorite
            )
        }
        let gaps = try modelContext.fetch(FetchDescriptor<HistoryGapRecord>()).map {
            ExportedGap(
                startedAt: $0.startedAt,
                endedAt: $0.endedAt,
                reason: $0.reason,
                diagnosis: $0.diagnosis,
                resolution: $0.resolution,
                resolvedAt: $0.resolvedAt,
                travelMode: $0.travelMode,
                estimatedDistanceMeters: $0.estimatedDistanceMeters,
                estimatedTravelTime: $0.estimatedTravelTime,
                estimatedRoute: $0.estimatedRoute
            )
        }
        return HistoryExport(
            schemaVersion: 2,
            exportedAt: .now,
            trips: trips,
            visits: visits,
            places: places,
            gaps: gaps
        )
    }

    private func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
