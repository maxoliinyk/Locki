//
//  SettingsViewTests.swift
//  LockiTests
//
//  Created by Max Oliinyk on 18.07.2026.
//

import SwiftUI
import Testing
import UIKit
@testable import Locki

@Suite("Settings interface")
@MainActor
struct SettingsViewTests {
    @Test("Minimal settings hub renders")
    func settingsHubRenders() {
        let settings = SettingsView(
            viewModel: MapViewModel(),
            historyModel: HistoryModel(),
            motionService: MotionActivityService()
        )
        .frame(width: 390, height: 844)

        #expect(ImageRenderer(content: settings).uiImage != nil)
    }
}
