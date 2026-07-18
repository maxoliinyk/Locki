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
    @UIApplicationDelegateAdaptor(LockiAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            if let runtime = appDelegate.runtime {
                RootView(runtime: runtime)
                    .modelContainer(runtime.modelContainer)
            } else {
                PersistenceUnavailableView()
            }
        }
    }
}

enum LockiPersistence {
    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        try ModelContainer(
            for: Schema(versionedSchema: LockiSchemaV4.self),
            migrationPlan: LockiSchemaMigrationPlan.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: inMemory)
        )
    }
}

private struct PersistenceUnavailableView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Unable to Open Private Data", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text(
                "Your location history is still stored on this device. Close and reopen Locki. "
                    + "If the problem continues, install the next available update."
            )
        }
    }
}
