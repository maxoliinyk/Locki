//
//  LockiMap.swift
//  Locki
//
//  Created by Max Oliinyk on 06.05.2026.
//

import MapKit
import SwiftUI

private extension LockiMapStyle {
    var mapStyle: MapStyle {
        switch self {
        case .standard:
            .standard(elevation: .realistic)
        case .imagery:
            .hybrid(elevation: .realistic)
        }
    }
}

struct LockiMap: View {
    @Bindable var viewModel: MapViewModel

    var body: some View {
        Map(position: $viewModel.cameraPosition) {
            if viewModel.showsUserLocation {
                UserAnnotation()
            }
        }
        .mapStyle(viewModel.mapStyle.mapStyle)
        .mapControls {
            MapCompass()
                .mapControlVisibility(.visible)
            MapPitchToggle()
            MapScaleView()
        }
    }
}

#Preview {
    @Previewable @State var viewModel = MapViewModel()

    LockiMap(viewModel: viewModel)
}
