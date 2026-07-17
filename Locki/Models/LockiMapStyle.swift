//
//  LockiMapStyle.swift
//  Locki
//
//  Created by Max Oliinyk on 07.05.2026.
//

import Foundation

nonisolated enum LockiMapStyle: String, CaseIterable, Identifiable, Sendable {
    case standard
    case imagery

    var id: Self { self }

    var title: String {
        switch self {
        case .standard:
            "Standard"
        case .imagery:
            "Satellite"
        }
    }

    var systemImage: String {
        switch self {
        case .standard:
            "map"
        case .imagery:
            "globe.europe.africa.fill"
        }
    }
}
