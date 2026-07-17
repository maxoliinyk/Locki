//
//  PlacesViewTests.swift
//  LockiTests
//
//  Created by Max Oliinyk on 17.07.2026.
//

import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import Locki

@Suite("Places interface")
@MainActor
struct PlacesViewTests {
    @Test("Places browser and detailed analytics render with live and historical visits")
    func placesDashboardRenders() throws {
        let container = try makeContainer()
        let now = Date.now
        let place = HistoryPlaceRecord(
            latitude: 52.52,
            longitude: 13.40,
            radiusMeters: 35,
            name: "Home"
        )
        place.isFavorite = true
        place.visitCount = 3
        place.distinctDayCount = 3
        place.totalDuration = 21_600
        container.mainContext.insert(place)
        for day in 0..<2 {
            container.mainContext.insert(
                HistoryVisitRecord(
                    placeID: place.id,
                    arrivalDate: now - Double((day + 1) * 86_400),
                    departureDate: now - Double((day + 1) * 86_400) + 3_600,
                    timeZoneIdentifier: "Europe/Berlin",
                    latitude: place.latitude,
                    longitude: place.longitude,
                    radiusMeters: 35,
                    sourceRawValue: "inferred",
                    quality: 0.9
                )
            )
        }
        container.mainContext.insert(
            HistoryVisitRecord(
                placeID: place.id,
                arrivalDate: now - 1_800,
                timeZoneIdentifier: "Europe/Berlin",
                latitude: place.latitude,
                longitude: place.longitude,
                radiusMeters: 35,
                sourceRawValue: "inferred",
                quality: 0.9
            )
        )
        try container.mainContext.save()

        let model = HistoryModel()
        let browser = NavigationStack { PlacesView(historyModel: model) }
            .modelContainer(container)
            .frame(width: 390, height: 844)
        let detail = NavigationStack { PlaceDetailView(place: place, historyModel: model) }
            .modelContainer(container)
            .frame(width: 390, height: 844)

        #expect(ImageRenderer(content: browser).uiImage != nil)
        #expect(ImageRenderer(content: detail).uiImage != nil)
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: HistoryPlaceRecord.self,
            HistoryVisitRecord.self,
            PlaceSuggestionPreferenceRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }
}
