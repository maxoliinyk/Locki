//
//  PathMatchingCoordinator.swift
//  Locki
//
//  Created by Max Oliinyk on 17.07.2026.
//

import Foundation

@MainActor
final class PathMatchingCoordinator {
    private let store: CoverageStore
    private let routeProvider: any PathRouteProviding
    private let matchingEngine: PathMatchingEngine
    private let explorationEngine: ExplorationEngine
    private let configuration: PathMatchingConfiguration
    private let coverageHandler: (CoverageDelta, PathMatchCommitResult) -> Void
    private let statusHandler: (Int, Int) -> Void
    private let persistenceIssueHandler: (Bool) -> Void

    private var processingTask: Task<Void, Never>?
    private var needsProcessing = false

    init(
        store: CoverageStore,
        routeProvider: any PathRouteProviding = MapKitPathRouteProvider(),
        configuration: PathMatchingConfiguration = .standard,
        coverageHandler: @escaping (CoverageDelta, PathMatchCommitResult) -> Void,
        statusHandler: @escaping (Int, Int) -> Void,
        persistenceIssueHandler: @escaping (Bool) -> Void
    ) {
        self.store = store
        self.routeProvider = routeProvider
        matchingEngine = PathMatchingEngine(configuration: configuration)
        explorationEngine = ExplorationEngine()
        self.configuration = configuration
        self.coverageHandler = coverageHandler
        self.statusHandler = statusHandler
        self.persistenceIssueHandler = persistenceIssueHandler
    }

    func enqueue(_ anchor: PathAnchor) {
        Task {
            do {
                let anchors = try await store.enqueuePathAnchor(anchor, configuration: configuration)
                let summary = try await store.summary()
                persistenceIssueHandler(false)
                statusHandler(anchors.count, summary.matchedPathCount)
                scheduleProcessing()
            } catch {
                persistenceIssueHandler(true)
            }
        }
    }

    func resume() {
        scheduleProcessing()
    }

    func purge() {
        processingTask?.cancel()
        processingTask = nil
        needsProcessing = false
        Task {
            do {
                try await store.purgePendingPathAnchors()
                let summary = try await store.summary()
                persistenceIssueHandler(false)
                statusHandler(0, summary.matchedPathCount)
            } catch {
                persistenceIssueHandler(true)
            }
        }
    }

    private func scheduleProcessing() {
        needsProcessing = true
        guard processingTask == nil else { return }
        processingTask = Task { [weak self] in
            guard let self else { return }
            while needsProcessing, !Task.isCancelled {
                needsProcessing = false
                await processLatestWindow()
            }
            processingTask = nil
        }
    }

    private func processLatestWindow(now: Date = .now) async {
        let anchors: [PathAnchor]
        do {
            anchors = try await store.pendingPathAnchors(now: now, configuration: configuration)
            let summary = try await store.summary()
            persistenceIssueHandler(false)
            statusHandler(anchors.count, summary.matchedPathCount)
        } catch {
            persistenceIssueHandler(true)
            return
        }

        let window = matchingEngine.matchingWindow(from: anchors, now: now)
        guard let terminal = window.last,
              let request = matchingEngine.routeRequest(for: window) else {
            return
        }
        do {
            guard try await store.beginPathMatchAttempt(
                    terminalAnchorID: terminal.id,
                    now: now,
                    configuration: configuration
                  ) else { return }
        } catch {
            persistenceIssueHandler(true)
            return
        }

        let candidates: [PathRouteCandidate]
        do {
            candidates = try await routeProvider.routes(for: request)
        } catch is CancellationError {
            return
        } catch {
            return
        }
        guard !Task.isCancelled,
              case let .matched(candidate) = matchingEngine.decide(anchors: window, candidates: candidates) else {
            return
        }
        let delta = explorationEngine.process(
            matchedPath: candidate.coordinates,
            unlockedAt: terminal.observedAt,
            radiusMeters: configuration.matchedPathRadiusMeters,
            spacingMeters: configuration.matchedPathSpacingMeters
        )
        do {
            try Task.checkCancellation()
            let result = try await store.commitMatchedPath(
                delta,
                consuming: Set(window.map(\.id)),
                retaining: terminal.id
            )
            persistenceIssueHandler(false)
            coverageHandler(delta, result)
            statusHandler(result.pendingAnchorCount, result.matchedPathCount)
        } catch is CancellationError {
            return
        } catch {
            persistenceIssueHandler(true)
            return
        }
    }
}
