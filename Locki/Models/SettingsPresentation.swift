//
//  SettingsPresentation.swift
//  Locki
//
//  Created by Max Oliinyk on 18.07.2026.
//

import Foundation

nonisolated enum SettingsPermissionState: String, Equatable, Sendable {
    case enabled
    case actionNeeded
    case optional
    case unavailable

    var title: String {
        switch self {
        case .enabled: "On"
        case .actionNeeded: "Action Needed"
        case .optional: "Optional"
        case .unavailable: "Unavailable"
        }
    }

    var systemImage: String {
        switch self {
        case .enabled: "checkmark.circle.fill"
        case .actionNeeded: "exclamationmark.circle.fill"
        case .optional: "minus.circle"
        case .unavailable: "xmark.circle"
        }
    }
}

nonisolated struct SettingsReadinessInput: Equatable, Sendable {
    let historyEnabled: Bool
    let location: SettingsPermissionState
    let preciseLocation: SettingsPermissionState
    let alwaysLocation: SettingsPermissionState
    let backgroundRefresh: SettingsPermissionState
    let motion: SettingsPermissionState
}

nonisolated struct SettingsReadiness: Equatable, Sendable {
    let title: String
    let systemImage: String
    let isReady: Bool

    static func evaluate(_ input: SettingsReadinessInput) -> SettingsReadiness {
        let foregroundReady = input.location == .enabled && input.preciseLocation == .enabled
        let historyReady = !input.historyEnabled
            || (input.alwaysLocation == .enabled && input.backgroundRefresh != .actionNeeded)
        let isReady = foregroundReady && historyReady
        return SettingsReadiness(
            title: isReady ? "Ready to Explore" : "Finish Setup",
            systemImage: isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
            isReady: isReady
        )
    }
}
