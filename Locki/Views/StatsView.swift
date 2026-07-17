//
//  StatsView.swift
//  Locki
//
//  Created by Max Oliinyk on 07.05.2026.
//

import SwiftData
import SwiftUI

struct StatsView: View {
    @Query private var summaries: [ExplorationSummaryRecord]

    private var summary: ExplorationSummaryRecord? {
        summaries.first { $0.key == "primary" }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Exploration") {
                    LabeledContent("Cleared street cells", value: (summary?.exploredCellCount ?? 0).formatted())
                    LabeledContent("Tracking", value: "Foreground + background")
                    LabeledContent("Storage", value: "On-device masks")

                    if let latestUnlockDate = summary?.lastUnlockDate {
                        LabeledContent("Last unlock") {
                            Text(latestUnlockDate, format: .dateTime.month().day().hour().minute())
                        }
                    }
                }

                if summary?.exploredCellCount ?? 0 == 0 {
                    Section {
                        ContentUnavailableView(
                            "No Stats Yet",
                            systemImage: "chart.bar.xaxis",
                            description: Text("Enable exploration and move through the world to begin clearing textured fog.")
                        )
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Stats")
        }
    }
}

#Preview {
    StatsView()
        .modelContainer(for: [ExplorationSummaryRecord.self], inMemory: true)
}
