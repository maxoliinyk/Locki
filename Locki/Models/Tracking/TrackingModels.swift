//
//  TrackingModels.swift
//  Locki
//
//  Created by Max Oliinyk on 17.07.2026.
//

import CoreLocation
import CoreMotion
import Foundation
import UIKit

@MainActor
protocol OneShotLocationProviding: AnyObject {
    func requestOneShotLocation(timeout: Duration) async -> Bool
}

nonisolated enum TrackingMode: String, CaseIterable, Identifiable, Sendable {
    case efficient
    case detailed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .efficient: "Efficient"
        case .detailed: "Detailed"
        }
    }

    var explanation: String {
        switch self {
        case .efficient:
            "Uses visits, meaningful movement, monitored places, motion, and background refresh with lower battery use. Routes may contain gaps."
        case .detailed:
            "Adds continuous background location for more complete routes and speed detail. Uses more battery and may show the location indicator."
        }
    }
}

nonisolated enum MotionActivityKind: String, Codable, Hashable, Sendable {
    case stationary
    case walking
    case running
    case cycling
    case automotive
    case unknown
}

nonisolated struct MotionActivitySample: Codable, Hashable, Sendable {
    let kind: MotionActivityKind
    let confidence: Int
    let startedAt: Date

    init(kind: MotionActivityKind, confidence: Int, startedAt: Date) {
        self.kind = kind
        self.confidence = confidence
        self.startedAt = startedAt
    }

    init(_ activity: CMMotionActivity) {
        let kind: MotionActivityKind
        if activity.stationary { kind = .stationary }
        else if activity.automotive { kind = .automotive }
        else if activity.cycling { kind = .cycling }
        else if activity.running { kind = .running }
        else if activity.walking { kind = .walking }
        else { kind = .unknown }
        self.init(kind: kind, confidence: activity.confidence.rawValue, startedAt: activity.startDate)
    }

    var isReliableStationary: Bool { kind == .stationary && confidence >= 1 }
    var isReliableMovement: Bool { kind != .stationary && kind != .unknown && confidence >= 1 }
}

nonisolated enum PlaceRegionState: String, Codable, Hashable, Sendable {
    case inside
    case outside
    case unknown
}

nonisolated struct PlaceRegionEvent: Codable, Hashable, Sendable {
    let placeID: UUID?
    let coordinate: GeoCoordinate
    let radiusMeters: Double
    let state: PlaceRegionState
    let date: Date
}

nonisolated enum HistoryReconciliationReason: String, Codable, Hashable, Sendable {
    case foreground
    case backgroundRefresh
    case locationRelaunch
}

nonisolated struct MonitoredPlaceCandidate: Hashable, Sendable {
    let placeID: UUID?
    let coordinate: GeoCoordinate
    let radiusMeters: Double
    let isCandidate: Bool
    let isFavorite: Bool
    let isUserNamed: Bool
    let visitCount: Int
    let totalDuration: TimeInterval
    let lastVisitAt: Date?
}

nonisolated struct ProvisionalStaySnapshot: Hashable, Sendable {
    let startedAt: Date
    let placeID: UUID?
    let placeName: String?
    let evidenceCount: Int
    let hasStationaryMotion: Bool

    func isCredible(at date: Date) -> Bool {
        date.timeIntervalSince(startedAt) >= 3 * 60 && (evidenceCount >= 2 || hasStationaryMotion || placeID != nil)
    }
}

@MainActor
@Observable
final class TrackingHealthModel {
    private(set) var lastPassiveEventAt: Date?
    private(set) var lastPassiveEventTitle: String?
    private(set) var lastRefreshAt: Date?
    private(set) var lastRefreshSucceeded: Bool?
    private(set) var monitoredPlaceCount = 0

    private let defaults: UserDefaults
    private static let passiveDateKey = "tracking.health.passiveDate"
    private static let passiveTitleKey = "tracking.health.passiveTitle"
    private static let refreshDateKey = "tracking.health.refreshDate"
    private static let refreshSuccessKey = "tracking.health.refreshSuccess"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        lastPassiveEventAt = defaults.object(forKey: Self.passiveDateKey) as? Date
        lastPassiveEventTitle = defaults.string(forKey: Self.passiveTitleKey)
        lastRefreshAt = defaults.object(forKey: Self.refreshDateKey) as? Date
        if defaults.object(forKey: Self.refreshSuccessKey) != nil {
            lastRefreshSucceeded = defaults.bool(forKey: Self.refreshSuccessKey)
        }
    }

    func recordPassiveEvent(_ title: String, at date: Date = .now) {
        if title == lastPassiveEventTitle,
           let lastPassiveEventAt,
           date.timeIntervalSince(lastPassiveEventAt) < 30 {
            self.lastPassiveEventAt = date
            return
        }
        lastPassiveEventAt = date
        lastPassiveEventTitle = title
        defaults.set(date, forKey: Self.passiveDateKey)
        defaults.set(title, forKey: Self.passiveTitleKey)
    }

    func recordRefresh(success: Bool, at date: Date = .now) {
        lastRefreshAt = date
        lastRefreshSucceeded = success
        defaults.set(date, forKey: Self.refreshDateKey)
        defaults.set(success, forKey: Self.refreshSuccessKey)
    }

    func setMonitoredPlaceCount(_ count: Int) {
        monitoredPlaceCount = count
    }
}

nonisolated extension UIBackgroundRefreshStatus {
    var trackingTitle: String {
        switch self {
        case .available: "Available"
        case .denied: "Off"
        case .restricted: "Restricted"
        @unknown default: "Unavailable"
        }
    }
}
