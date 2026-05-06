//
//  HistoryView.swift
//  Locki
//
//  Created by Max Oliinyk on 06.05.2026.
//

import SwiftUI

struct HistoryView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "No History Yet",
                systemImage: "clock.badge.questionmark",
                description: Text("Your visits and routes will appear here once tracking is added.")
            )
            .navigationTitle("History")
        }
    }
}

#Preview {
    HistoryView()
}
