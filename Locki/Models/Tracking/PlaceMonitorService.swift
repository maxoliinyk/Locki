//
//  PlaceMonitorService.swift
//  Locki
//
//  Created by Max Oliinyk on 17.07.2026.
//

import CoreLocation
import Foundation
import Observation

@MainActor
protocol PlaceMonitoring: AnyObject {
    var eventHandler: ((PlaceRegionEvent) -> Void)? { get set }
    var monitoredCount: Int { get }
    func update(_ candidates: [MonitoredPlaceCandidate]) async
    func reconcile() async
    func removeAll() async
}

@MainActor
@Observable
final class PlaceMonitorService: PlaceMonitoring {
    private(set) var monitoredCount = 0
    @ObservationIgnored var eventHandler: ((PlaceRegionEvent) -> Void)?

    @ObservationIgnored private var monitor: CLMonitor?
    @ObservationIgnored private var monitorCreationTask: Task<CLMonitor, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var monitored: [String: MonitoredPlaceCandidate] = [:]

    private static let monitorName = "LockiPlaceHistory"
    private static let candidateIdentifier = "candidate"
    private static let maximumConditionCount = 16

    func update(_ candidates: [MonitoredPlaceCandidate]) async {
        let selected = Self.selectedCandidates(from: candidates)
        let desired = Dictionary(uniqueKeysWithValues: selected.map { (Self.identifier(for: $0), $0) })
        let monitor = await ensureMonitor()
        let existingIdentifiers = await monitor.identifiers

        for identifier in existingIdentifiers where desired[identifier] == nil {
            await monitor.remove(identifier)
            monitored.removeValue(forKey: identifier)
        }

        for (identifier, candidate) in desired {
            if let existing = monitored[identifier], existing == candidate { continue }
            let condition = CLMonitor.CircularGeographicCondition(
                center: CLLocationCoordinate2D(
                    latitude: candidate.coordinate.latitude,
                    longitude: candidate.coordinate.longitude
                ),
                radius: min(max(candidate.radiusMeters, 100), 200)
            )
            if let record = await monitor.record(for: identifier),
               let existingCondition = record.condition as? CLMonitor.CircularGeographicCondition,
               GeoCoordinate(existingCondition.center).distance(to: candidate.coordinate) < 1,
               abs(existingCondition.radius - condition.radius) < 1 {
                monitored[identifier] = candidate
                deliver(record.lastEvent, candidate: candidate)
                continue
            }
            if existingIdentifiers.contains(identifier) || monitored[identifier] != nil {
                await monitor.remove(identifier)
            }
            monitored[identifier] = candidate
            await monitor.add(condition, identifier: identifier, assuming: .unknown)
        }
        monitoredCount = monitored.count
    }

    func reconcile() async {
        guard let monitor else { return }
        for (identifier, candidate) in monitored {
            guard let record = await monitor.record(for: identifier) else { continue }
            deliver(record.lastEvent, candidate: candidate)
        }
    }

    func removeAll() async {
        let monitor = await ensureMonitor()
        for identifier in await monitor.identifiers { await monitor.remove(identifier) }
        monitored.removeAll()
        monitoredCount = 0
    }

    static func selectedCandidates(from candidates: [MonitoredPlaceCandidate]) -> [MonitoredPlaceCandidate] {
        let sorted = candidates.sorted { left, right in
            if left.isCandidate != right.isCandidate { return left.isCandidate }
            if left.isFavorite != right.isFavorite { return left.isFavorite }
            if left.isUserNamed != right.isUserNamed { return left.isUserNamed }
            if left.lastVisitAt != right.lastVisitAt {
                return (left.lastVisitAt ?? .distantPast) > (right.lastVisitAt ?? .distantPast)
            }
            if left.visitCount != right.visitCount { return left.visitCount > right.visitCount }
            return left.totalDuration > right.totalDuration
        }

        var selected: [MonitoredPlaceCandidate] = []
        for candidate in sorted {
            guard candidate.coordinate.isValid else { continue }
            let overlaps = selected.contains {
                !$0.isCandidate && !candidate.isCandidate
                    && $0.coordinate.distance(to: candidate.coordinate)
                        < min(max($0.radiusMeters, 100), max(candidate.radiusMeters, 100)) * 0.6
            }
            if !overlaps { selected.append(candidate) }
            if selected.count == maximumConditionCount { break }
        }
        return selected
    }

    private func ensureMonitor() async -> CLMonitor {
        if let monitor { return monitor }

        let creationTask: Task<CLMonitor, Never>
        if let monitorCreationTask {
            creationTask = monitorCreationTask
        } else {
            let task = Task { await CLMonitor(Self.monitorName) }
            monitorCreationTask = task
            creationTask = task
        }

        let created = await creationTask.value
        if let monitor { return monitor }

        monitor = created
        monitorCreationTask = nil
        eventTask = Task { [weak self] in
            do {
                for try await event in await created.events {
                    guard let self, let candidate = self.monitored[event.identifier] else { continue }
                    self.deliver(event, candidate: candidate)
                }
            } catch is CancellationError {
                // Process teardown.
            } catch {
                // Core Location will provide current records again during reconciliation.
            }
        }
        return created
    }

    private func deliver(_ event: CLMonitor.Event, candidate: MonitoredPlaceCandidate) {
        let state: PlaceRegionState = switch event.state {
        case .satisfied: .inside
        case .unsatisfied: .outside
        case .unknown, .unmonitored: .unknown
        @unknown default: .unknown
        }
        eventHandler?(
            PlaceRegionEvent(
                placeID: candidate.placeID,
                coordinate: candidate.coordinate,
                radiusMeters: candidate.radiusMeters,
                state: state,
                date: event.date
            )
        )
    }

    private static func identifier(for candidate: MonitoredPlaceCandidate) -> String {
        if candidate.isCandidate { return candidateIdentifier }
        return "place.\(candidate.placeID?.uuidString ?? UUID().uuidString)"
    }
}
