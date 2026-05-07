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
                description: Text("Your private location journal will appear here once passive tracking is added.")
            )
            .navigationTitle("Journal")
        }
    }
}

#Preview {
    JournalView()
}
