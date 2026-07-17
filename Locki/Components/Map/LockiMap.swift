//
//  LockiMap.swift
//  Locki
//
//  Created by Max Oliinyk on 06.05.2026.
//

import MapKit
import SwiftUI

struct LockiMap: UIViewRepresentable {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    let viewModel: MapViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsCompass = true
        mapView.showsScale = true
        mapView.isPitchEnabled = true
        mapView.isRotateEnabled = true
        mapView.pointOfInterestFilter = .includingAll
        mapView.addOverlay(context.coordinator.fogOverlay, level: .aboveLabels)
        context.coordinator.mapView = mapView
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self
        mapView.mapType = viewModel.mapStyle == .standard ? .standard : .hybridFlyover
        mapView.showsUserLocation = viewModel.showsUserLocation
        context.coordinator.renderer?.update(
            snapshot: viewModel.coverageSnapshot,
            style: FogRenderStyle(
                mapStyle: viewModel.mapStyle,
                reduceTransparency: reduceTransparency,
                increasedContrast: colorSchemeContrast == .increased
            )
        )

        if context.coordinator.lastRecenterRequest != viewModel.recenterRequest {
            context.coordinator.lastRecenterRequest = viewModel.recenterRequest
            if viewModel.showsUserLocation {
                mapView.setUserTrackingMode(.follow, animated: true)
            }
        }

        if viewModel.showsUserLocation, !context.coordinator.wasShowingUserLocation {
            context.coordinator.wasShowingUserLocation = true
            mapView.setUserTrackingMode(.follow, animated: true)
        } else if !viewModel.showsUserLocation {
            context.coordinator.wasShowingUserLocation = false
        }
    }

    static func dismantleUIView(_ mapView: MKMapView, coordinator: Coordinator) {
        mapView.delegate = nil
        mapView.removeOverlay(coordinator.fogOverlay)
        coordinator.renderer = nil
        coordinator.mapView = nil
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: LockiMap
        weak var mapView: MKMapView?
        let fogOverlay = WorldFogOverlay()
        var renderer: FogOverlayRenderer?
        var lastRecenterRequest = 0
        var wasShowingUserLocation = false

        init(parent: LockiMap) {
            self.parent = parent
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            guard overlay === fogOverlay else { return MKOverlayRenderer(overlay: overlay) }
            if let renderer { return renderer }
            let renderer = FogOverlayRenderer(overlay: fogOverlay)
            self.renderer = renderer
            renderer.update(
                snapshot: parent.viewModel.coverageSnapshot,
                style: FogRenderStyle(
                    mapStyle: parent.viewModel.mapStyle,
                    reduceTransparency: false,
                    increasedContrast: false
                )
            )
            return renderer
        }
    }
}

#Preview {
    LockiMap(viewModel: MapViewModel())
}
