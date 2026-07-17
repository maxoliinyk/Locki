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

    private var processingTask: Task<PathProcessingResult, Never>?
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

    func processPending(
        now: Date = .now,
        deadline: Date? = nil
    ) async -> PathProcessingResult {
        needsProcessing = true
        return await scheduleProcessing(now: now, deadline: deadline).value
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

    @discardableResult
    private func scheduleProcessing(
        now: Date = .now,
        deadline: Date? = nil
    ) -> Task<PathProcessingResult, Never> {
        needsProcessing = true
        if let processingTask { return processingTask }
        let task = Task { [weak self] in
            guard let self else { return PathProcessingResult.idle }
            var result: PathProcessingResult = .idle
            while needsProcessing, !Task.isCancelled {
                needsProcessing = false
                result = await processLatestWindow(now: now, deadline: deadline)
            }
            processingTask = nil
            return result
        }
        processingTask = task
        return task
    }

    private func processLatestWindow(now: Date, deadline: Date?) async -> PathProcessingResult {
        guard deadline.map({ Date.now < $0 }) ?? true else { return .deferred(.cancelled) }
        let anchors: [PathAnchor]
        do {
            anchors = try await store.pendingPathAnchors(now: now, configuration: configuration)
            let summary = try await store.summary()
            persistenceIssueHandler(false)
            statusHandler(anchors.count, summary.matchedPathCount)
        } catch {
            persistenceIssueHandler(true)
            return .deferred(.routeUnavailable)
        }

        let window = matchingEngine.matchingWindow(from: anchors, now: now)
        guard let terminal = window.last,
              let request = matchingEngine.routeRequest(for: window) else {
            return .idle
        }
        do {
            guard try await store.beginPathMatchAttempt(
                terminalAnchorID: terminal.id,
                now: now,
                configuration: configuration
            ) else { return .idle }
        } catch {
            persistenceIssueHandler(true)
            return .deferred(.routeUnavailable)
        }

        let primaryCandidates: [PathRouteCandidate]
        do {
            try checkExecution(deadline: deadline)
            primaryCandidates = try await routeProvider.routes(for: request)
        } catch is CancellationError {
            await recordFailure(.cancelled, terminal: terminal, now: now)
            return .deferred(.cancelled)
        } catch {
            await recordFailure(.routeUnavailable, terminal: terminal, now: now)
            return .deferred(.routeUnavailable)
        }

        let primaryDecision = matchingEngine.decide(anchors: window, candidates: primaryCandidates)
        if case let .matched(candidate) = primaryDecision {
            return await commit(candidate, window: window, terminal: terminal)
        }

        let fallbackWindows = matchingEngine.fallbackWindows(
            for: window,
            primaryCandidates: primaryCandidates
        )
        guard !fallbackWindows.isEmpty else {
            let failure = failureKind(for: primaryDecision)
            await recordFailure(failure, terminal: terminal, now: now)
            return .deferred(failure)
        }

        var legCandidates: [[PathRouteCandidate]] = []
        do {
            for leg in fallbackWindows {
                try checkExecution(deadline: deadline)
                guard let first = leg.first, let last = leg.last, first.id != last.id else {
                    throw PathMatchingExecutionError.invalidLeg
                }
                let legRequest = PathRouteRequest(
                    source: first.coordinate,
                    destination: last.coordinate,
                    departureDate: first.observedAt,
                    modes: request.modes
                )
                let candidates = try await routeProvider.routes(for: legRequest)
                guard !candidates.isEmpty else { throw PathMatchingExecutionError.noCandidates }
                legCandidates.append(candidates)
            }
        } catch is CancellationError {
            await recordFailure(.cancelled, terminal: terminal, now: now)
            return .deferred(.cancelled)
        } catch {
            await recordFailure(.routeUnavailable, terminal: terminal, now: now)
            return .deferred(.routeUnavailable)
        }

        let stitched = matchingEngine.stitchedCandidates(from: legCandidates)
        let fallbackDecision = matchingEngine.decide(anchors: window, candidates: stitched)
        guard case let .matched(candidate) = fallbackDecision else {
            let failure = failureKind(for: fallbackDecision)
            await recordFailure(failure, terminal: terminal, now: now)
            return .deferred(failure)
        }
        return await commit(candidate, window: window, terminal: terminal)
    }

    private func commit(
        _ candidate: PathRouteCandidate,
        window: [PathAnchor],
        terminal: PathAnchor
    ) async -> PathProcessingResult {
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
            return .matched
        } catch is CancellationError {
            return .deferred(.cancelled)
        } catch {
            persistenceIssueHandler(true)
            return .deferred(.routeUnavailable)
        }
    }

    private func recordFailure(_ failure: PathMatchFailureKind, terminal: PathAnchor, now: Date) async {
        do {
            try await store.recordPathMatchFailure(
                terminalAnchorID: terminal.id,
                failure: failure,
                now: now,
                configuration: configuration
            )
            persistenceIssueHandler(false)
        } catch {
            persistenceIssueHandler(true)
        }
    }

    private func failureKind(for decision: PathMatchDecision) -> PathMatchFailureKind {
        switch decision {
        case .insufficientEvidence: .insufficientEvidence
        case .ambiguous: .ambiguous
        case .temporarilyUnavailable: .routeUnavailable
        case .permanentlyRejected: .rejected
        case .matched: .rejected
        }
    }

    private func checkExecution(deadline: Date?) throws {
        try Task.checkCancellation()
        if let deadline, Date.now >= deadline { throw CancellationError() }
    }
}

private enum PathMatchingExecutionError: Error {
    case invalidLeg
    case noCandidates
}
