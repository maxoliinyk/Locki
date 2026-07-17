//
//  BackgroundRefreshCoordinator.swift
//  Locki
//
//  Created by Max Oliinyk on 17.07.2026.
//

import BackgroundTasks
import Foundation

nonisolated enum BackgroundRefreshPolicy {
    static let earliestDelay: TimeInterval = 30 * 60

    static func shouldSchedule(historyEnabled: Bool) -> Bool { historyEnabled }
}

@MainActor
protocol BackgroundRefreshScheduling: AnyObject {
    func register(handler: @escaping @MainActor (BGAppRefreshTask) -> Void)
    func schedule()
    func cancel()
}

@MainActor
final class BackgroundRefreshCoordinator: BackgroundRefreshScheduling {
    static let identifier = "com.maxoliinyk.Locki.history-refresh"

    private let scheduler: BGTaskScheduler
    private var isRegistered = false
    private var hasPendingRequest = false

    init(scheduler: BGTaskScheduler = .shared) {
        self.scheduler = scheduler
    }

    func register(handler: @escaping @MainActor (BGAppRefreshTask) -> Void) {
        guard !isRegistered else { return }
        isRegistered = scheduler.register(
            forTaskWithIdentifier: Self.identifier,
            using: .main
        ) { [weak self] task in
            MainActor.assumeIsolated {
                self?.hasPendingRequest = false
                guard let refreshTask = task as? BGAppRefreshTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                handler(refreshTask)
            }
        }
    }

    func schedule() {
        guard isRegistered, !hasPendingRequest else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.identifier)
        request.earliestBeginDate = .now + BackgroundRefreshPolicy.earliestDelay
        do {
            try scheduler.submit(request)
            hasPendingRequest = true
        } catch {
            // Settings exposes the refresh status; scheduling is always best effort.
        }
    }

    func cancel() {
        scheduler.cancel(taskRequestWithIdentifier: Self.identifier)
        hasPendingRequest = false
    }
}
