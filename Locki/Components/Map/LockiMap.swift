//
//  LockiMap.swift
//  Locki
//
//  Created by Max Oliinyk on 06.05.2026.
//

import MapKit
import SwiftUI

struct LockiMap: View {
    @Bindable var viewModel: MapViewModel

    var body: some View {
        Map(position: $viewModel.cameraPosition) {
            if viewModel.showsUserLocation {
                UserAnnotation()
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .mapControls {
            MapCompass()
            MapPitchToggle()
            MapScaleView()
        }
    }
}

#Preview {
    @Previewable @State var viewModel = MapViewModel()

    LockiMap(viewModel: viewModel)
}
