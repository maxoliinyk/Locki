//
//  JournalView.swift
//  Locki
//
//  Created by Max Oliinyk on 06.05.2026.
//

import SwiftUI

struct JournalView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "No Journal Yet",
                systemImage: "book.pages",
                description: Text("Visit summaries and notes will appear here after the exploration foundation is stable.")
            )
            .navigationTitle("Journal")
        }
    }
}

#Preview {
    JournalView()
}
