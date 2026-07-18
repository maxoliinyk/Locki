//
//  StatsViewTests.swift
//  LockiTests
//
//  Created by Max Oliinyk on 18.07.2026.
//

import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import Locki

@Suite("Stats interface")
@MainActor
struct StatsViewTests {
    @Test("Stats dashboard renders daily summaries and chart data")
    func dashboardRenders() throws {
        let container = try ModelContainer(
            for: ExplorationSummaryRecord.self,
            HistoryDailySummaryRecord.self,
            HistoryPlaceRecord.self,
            HistoryRoutePatternRecord.self,
            HistoryTripRecord.self,
            HistoryVisitRecord.self,
            PlaceSuggestionPreferenceRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let day = HistoryDailySummaryRecord(
            dayStart: Calendar.current.startOfDay(for: .now),
            timeZoneIdentifier: TimeZone.current.identifier
        )
        day.distanceMeters = 4_200
        day.movingDuration = 2_400
        day.placeDuration = 18_000
        day.tripCount = 2
        day.visitCount = 1
        day.completeness = 0.8
        container.mainContext.insert(day)
        container.mainContext.insert(ExplorationSummaryRecord(exploredCellCount: 42))
        try container.mainContext.save()

        let dashboard = StatsView(historyModel: HistoryModel())
            .modelContainer(container)
            .frame(width: 390, height: 844)

        #expect(ImageRenderer(content: dashboard).uiImage != nil)
    }
}
