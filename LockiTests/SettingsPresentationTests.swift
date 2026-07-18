//
//  SettingsPresentationTests.swift
//  LockiTests
//
//  Created by Max Oliinyk on 18.07.2026.
//

import Testing
@testable import Locki

@Suite("Settings readiness")
struct SettingsPresentationTests {
    @Test("Foreground exploration is ready with location and precision")
    func foregroundReady() {
        let readiness = SettingsReadiness.evaluate(input(historyEnabled: false))

        #expect(readiness.isReady)
        #expect(readiness.title == "Ready to Explore")
    }

    @Test("History requires Always Location")
    func historyNeedsAlwaysLocation() {
        let readiness = SettingsReadiness.evaluate(
            input(historyEnabled: true, alwaysLocation: .actionNeeded)
        )

        #expect(!readiness.isReady)
        #expect(readiness.title == "Finish Setup")
    }

    @Test("Denied background refresh needs action when history is enabled")
    func historyNeedsBackgroundRefresh() {
        let readiness = SettingsReadiness.evaluate(
            input(historyEnabled: true, backgroundRefresh: .actionNeeded)
        )

        #expect(!readiness.isReady)
    }

    @Test("Restricted background refresh and optional motion do not block setup")
    func optionalStates() {
        let readiness = SettingsReadiness.evaluate(
            input(historyEnabled: true, backgroundRefresh: .unavailable, motion: .optional)
        )

        #expect(readiness.isReady)
    }

    @Test("Missing foreground permissions always need action")
    func missingForegroundPermissions() {
        #expect(!SettingsReadiness.evaluate(input(location: .actionNeeded)).isReady)
        #expect(!SettingsReadiness.evaluate(input(preciseLocation: .actionNeeded)).isReady)
    }

    private func input(
        historyEnabled: Bool = false,
        location: SettingsPermissionState = .enabled,
        preciseLocation: SettingsPermissionState = .enabled,
        alwaysLocation: SettingsPermissionState = .enabled,
        backgroundRefresh: SettingsPermissionState = .enabled,
        motion: SettingsPermissionState = .enabled
    ) -> SettingsReadinessInput {
        SettingsReadinessInput(
            historyEnabled: historyEnabled,
            location: location,
            preciseLocation: preciseLocation,
            alwaysLocation: alwaysLocation,
            backgroundRefresh: backgroundRefresh,
            motion: motion
        )
    }
}
