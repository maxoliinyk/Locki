//
//  LockiApp.swift
//  Locki
//
//  Created by Max Oliinyk on 06.05.2026.
//

import SwiftData
import SwiftUI

@main
struct LockiApp: App {
    private let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try ModelContainer(
                for: Schema(versionedSchema: LockiSchemaV3.self),
                migrationPlan: LockiSchemaMigrationPlan.self
            )
        } catch {
            preconditionFailure("Locki could not open its private local database: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(modelContainer)
    }
}
