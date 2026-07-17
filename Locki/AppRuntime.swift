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
    let motionService: MotionActivityService
    let placeMonitor: PlaceMonitorService
    let backgroundRefresh: BackgroundRefreshCoordinator
    let trackingHealth: TrackingHealthModel

    private var started = false

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        let locationTracking = LocationTrackingService()
        self.locationTracking = locationTracking
        mapViewModel = MapViewModel(locationTracking: locationTracking)
        historyModel = HistoryModel()
        motionService = MotionActivityService()
        placeMonitor = PlaceMonitorService()
        backgroundRefresh = BackgroundRefreshCoordinator()
        trackingHealth = TrackingHealthModel()
    }

    func start(launchedForLocation: Bool) {
        guard !started else {
            if launchedForLocation {
                Task { await historyModel.reconcile(reason: .locationRelaunch) }
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
            Task { await historyModel.reconcile(reason: .locationRelaunch) }
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
            task.setTaskCompleted(success: success)
        }
        task.expirationHandler = { work.cancel() }
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
