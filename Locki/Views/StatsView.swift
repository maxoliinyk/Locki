//
//  StatsView.swift
//  Locki
//
//  Created by Max Oliinyk on 07.05.2026.
//

import SwiftUI

struct StatsView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "No Stats Yet",
                systemImage: "chart.bar.xaxis",
                description: Text("Exploration progress, unlocked tiles, and achievements will appear here later.")
            )
            .navigationTitle("Stats")
        }
    }
}

#Preview {
    StatsView()
}
