//
//  TrackingMode.swift
//  Locki
//
//  Created by Max Oliinyk on 06.05.2026.
//

import Foundation

enum TrackingMode: String, CaseIterable, Identifiable {
    case paused
    case standard
    case activeRoute

    var id: Self { self }

    var title: String {
        switch self {
        case .paused:
            "Paused"
        case .standard:
            "Standard"
        case .activeRoute:
            "Active Route"
        }
    }

    var description: String {
        switch self {
        case .paused:
            "Tracking is paused."
        case .standard:
            "Ready for tracking."
        case .activeRoute:
            "A visible route session is active."
        }
    }

    var summary: String {
        switch self {
        case .paused:
            "No location updates are being recorded."
        case .standard:
            "Low-frequency updates for nearby context."
        case .activeRoute:
            "High-accuracy updates for this route."
        }
    }
}
