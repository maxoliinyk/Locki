//
//  MotionActivityService.swift
//  Locki
//
//  Created by Max Oliinyk on 17.07.2026.
//

import CoreMotion
import Foundation
import Observation

@MainActor
protocol MotionActivityProviding: AnyObject {
    var authorizationStatus: CMAuthorizationStatus { get }
    var isAvailable: Bool { get }
    var eventHandler: ((MotionActivitySample) -> Void)? { get set }
    func requestAuthorization()
    func start()
    func stop()
    func historicalActivity(from start: Date, to end: Date) async -> [MotionActivitySample]
}

@MainActor
@Observable
final class MotionActivityService: MotionActivityProviding {
    private(set) var authorizationStatus: CMAuthorizationStatus
    let isAvailable: Bool
    @ObservationIgnored var eventHandler: ((MotionActivitySample) -> Void)?

    @ObservationIgnored private let manager: CMMotionActivityManager
    @ObservationIgnored private var isRunning = false

    init(manager: CMMotionActivityManager = CMMotionActivityManager()) {
        self.manager = manager
        isAvailable = CMMotionActivityManager.isActivityAvailable()
        authorizationStatus = CMMotionActivityManager.authorizationStatus()
    }

    func requestAuthorization() {
        guard isAvailable, authorizationStatus == .notDetermined else {
            if authorizationStatus == .authorized { start() }
            return
        }
        manager.queryActivityStarting(from: .now - 60, to: .now, to: .main) { [weak self] activities, _ in
            Task { @MainActor in
                guard let self else { return }
                self.authorizationStatus = CMMotionActivityManager.authorizationStatus()
                activities?.map(MotionActivitySample.init).forEach { self.eventHandler?($0) }
                if self.authorizationStatus == .authorized { self.start() }
            }
        }
    }

    func start() {
        authorizationStatus = CMMotionActivityManager.authorizationStatus()
        guard isAvailable, authorizationStatus == .authorized, !isRunning else { return }
        isRunning = true
        manager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let activity else { return }
            Task { @MainActor in self?.eventHandler?(MotionActivitySample(activity)) }
        }
    }

    func stop() {
        guard isRunning else { return }
        manager.stopActivityUpdates()
        isRunning = false
    }

    func historicalActivity(from start: Date, to end: Date) async -> [MotionActivitySample] {
        authorizationStatus = CMMotionActivityManager.authorizationStatus()
        guard isAvailable, authorizationStatus == .authorized, end > start else { return [] }
        return await withCheckedContinuation { continuation in
            manager.queryActivityStarting(from: start, to: end, to: .main) { activities, _ in
                continuation.resume(returning: activities?.map(MotionActivitySample.init) ?? [])
            }
        }
    }
}
