//
//  StatusCard.swift
//  Locki
//
//  Created by Max Oliinyk on 06.05.2026.
//

import SwiftUI

struct StatusCard: View {
    let title: String
    let message: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .imageScale(.large)
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .bold()

                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
        .background(.regularMaterial, in: .rect(cornerRadius: 20))
    }
}

#Preview {
    StatusCard(
        title: "Exploring",
        message: "Location tracking is active.",
        systemImage: "pause.circle.fill",
        tint: .secondary
    )
    .padding()
}
