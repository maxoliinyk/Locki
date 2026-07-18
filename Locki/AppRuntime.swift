//
//  AppRuntime.swift
//  Locki
//
//  Created by Max Oliinyk on 17.07.2026.
//

import BackgroundTasks
import SwiftData
import UIKit

@MainActor
final class AppRuntime {
    let modelContainer: ModelContainer
    let locationTracking: LocationTrackingService
    let mapViewModel: MapViewModel
    let historyModel: HistoryModel
    let backupModel: BackupModel
    let motionService: MotionActivityService
    let placeMonitor: PlaceMonitorService
    let backgroundRefresh: BackgroundRefreshCoordinator
    let trackingHealth: TrackingHealthModel

    private var started = false
    private var locationRelaunchTask: Task<Void, Never>?
    private var locationBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        let locationTracking = LocationTrackingService()
        self.locationTracking = locationTracking
        mapViewModel = MapViewModel(locationTracking: locationTracking)
        let historyModel = HistoryModel()
        self.historyModel = historyModel
        motionService = MotionActivityService()
        placeMonitor = PlaceMonitorService()
        backgroundRefresh = BackgroundRefreshCoordinator()
        trackingHealth = TrackingHealthModel()
        backupModel = BackupModel(
            store: BackupStore(modelContainer: modelContainer),
            historyModel: historyModel,
            mapViewModel: mapViewModel
        )
    }

    func start(launchedForLocation: Bool) {
        guard !started else {
            if launchedForLocation {
                processLocationRelaunch()
            }
            return
        }
        started = true
        locationTracking.setApplicationIsActive(false)

        backgroundRefresh.register { [weak self] task in self?.handle(task) }
        historyModel.configure(
            modelContainer: modelContainer,
            locationTracking: locationTracking,
            motionService: motionService,
            placeMonitor: placeMonitor,
            backgroundRefresh: backgroundRefresh,
            trackingHealth: trackingHealth
        )
        mapViewModel.configurePersistence(modelContainer: modelContainer)

        if launchedForLocation {
            trackingHealth.recordPassiveEvent("Location relaunch")
            processLocationRelaunch()
        }
    }

    func applicationDidBecomeActive() {
        mapViewModel.setApplicationIsActive(true)
        Task { await historyModel.reconcile(reason: .foreground) }
    }

    func applicationDidEnterBackground() {
        mapViewModel.setApplicationIsActive(false)
        mapViewModel.flushCoverage()
    }

    private func handle(_ task: BGAppRefreshTask) {
        if historyModel.isEnabled {
            backgroundRefresh.schedule()
        } else {
            backgroundRefresh.cancel()
        }
        let work = Task { @MainActor [weak self] in
            let success = await self?.historyModel.performBackgroundRefresh() ?? false
            let deadline = Date.now + 20
            _ = await self?.mapViewModel.processPendingPathMatches(deadline: deadline)
            task.setTaskCompleted(success: success && !Task.isCancelled)
        }
        task.expirationHandler = { work.cancel() }
    }

    private func processLocationRelaunch() {
        locationRelaunchTask?.cancel()
        endLocationBackgroundTask()
        locationBackgroundTaskID = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.locationRelaunchTask?.cancel()
            self?.endLocationBackgroundTask()
        }
        locationRelaunchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await historyModel.reconcile(reason: .locationRelaunch)
            _ = await mapViewModel.processPendingPathMatches(deadline: .now + 20)
            endLocationBackgroundTask()
            locationRelaunchTask = nil
        }
    }

    private func endLocationBackgroundTask() {
        guard locationBackgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(locationBackgroundTaskID)
        locationBackgroundTaskID = .invalid
    }
}

@MainActor
final class LockiAppDelegate: NSObject, UIApplicationDelegate {
    let runtime: AppRuntime?

    override init() {
        if let container = try? LockiPersistence.makeContainer() {
            runtime = AppRuntime(modelContainer: container)
        } else {
            runtime = nil
        }
        super.init()
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        runtime?.start(launchedForLocation: launchOptions?[.location] != nil)
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        runtime?.applicationDidBecomeActive()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        runtime?.applicationDidEnterBackground()
    }
}
