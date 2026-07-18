//
//  FogOverlayRenderer.swift
//  Locki
//
//  Created by Max Oliinyk on 17.07.2026.
//

import MapKit
import UIKit

nonisolated final class WorldFogOverlay: NSObject, MKOverlay {
    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let boundingMapRect = MKMapRect.world
}

nonisolated enum FogInterfaceStyle: CaseIterable, Equatable, Sendable {
    case light
    case dark
}

nonisolated struct FogColorComponents: Equatable, Sendable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat

    var relativeLuminance: CGFloat {
        0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    var uiColor: UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}

nonisolated struct FogPalette: Equatable, Sendable {
    let base: FogColorComponents
    let highlight: FogColorComponents
}

nonisolated struct FogRenderStyle: Equatable {
    let mapStyle: LockiMapStyle
    let interfaceStyle: FogInterfaceStyle
    let reduceTransparency: Bool
    let increasedContrast: Bool

    var palette: FogPalette {
        let contrastBoost: CGFloat = increasedContrast ? (interfaceStyle == .dark ? 0.06 : 0.1) : 0
        let base: FogColorComponents
        let highlightAlpha: CGFloat

        switch (mapStyle, interfaceStyle) {
        case (.standard, .light):
            base = FogColorComponents(
                red: 0.58,
                green: 0.66,
                blue: 0.64,
                alpha: reduceTransparency ? 0.94 : 0.76
            )
            highlightAlpha = 0.035
        case (.standard, .dark):
            base = FogColorComponents(
                red: 0.18,
                green: 0.23,
                blue: 0.22,
                alpha: reduceTransparency ? 0.96 : 0.86
            )
            highlightAlpha = 0.025
        case (.imagery, .light):
            base = FogColorComponents(
                red: 0.34,
                green: 0.39,
                blue: 0.38,
                alpha: reduceTransparency ? 0.96 : 0.82
            )
            highlightAlpha = 0.045
        case (.imagery, .dark):
            base = FogColorComponents(
                red: 0.10,
                green: 0.14,
                blue: 0.13,
                alpha: reduceTransparency ? 0.97 : 0.90
            )
            highlightAlpha = 0.03
        }

        return FogPalette(
            base: FogColorComponents(
                red: max(base.red - contrastBoost, 0),
                green: max(base.green - contrastBoost, 0),
                blue: max(base.blue - contrastBoost, 0),
                alpha: base.alpha
            ),
            highlight: FogColorComponents(red: 1, green: 1, blue: 1, alpha: highlightAlpha)
        )
    }
}

nonisolated final class FogOverlayRenderer: MKOverlayRenderer {
    private var snapshot: CoverageSnapshot = .empty
    private var style = FogRenderStyle(
        mapStyle: .standard,
        interfaceStyle: .light,
        reduceTransparency: false,
        increasedContrast: false
    )

    func update(snapshot: CoverageSnapshot, style: FogRenderStyle) {
        guard self.snapshot.generation != snapshot.generation || self.style != style else { return }
        self.snapshot = snapshot
        self.style = style
        setNeedsDisplay()
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let drawRect = rect(for: mapRect)
        context.saveGState()
        drawFog(in: drawRect, mapRect: mapRect, zoomScale: zoomScale, context: context)
        carveCoverage(in: mapRect, zoomScale: zoomScale, context: context)
        context.restoreGState()
    }

    private func drawFog(
        in drawRect: CGRect,
        mapRect: MKMapRect,
        zoomScale: MKZoomScale,
        context: CGContext
    ) {
        let palette = style.palette
        context.setBlendMode(.normal)
        context.setFillColor(palette.base.uiColor.cgColor)
        context.fill(drawRect)

        guard !style.reduceTransparency else { return }

        let spacing = max(60 / Double(zoomScale), 1)
        let firstX = Int(floor(mapRect.minX / spacing))
        let lastX = Int(ceil(mapRect.maxX / spacing))
        let firstY = Int(floor(mapRect.minY / spacing))
        let lastY = Int(ceil(mapRect.maxY / spacing))

        for gridY in firstY...lastY {
            for gridX in firstX...lastX {
                let seed = stableHash(x: gridX, y: gridY)
                let width = spacing * (0.75 + Double(seed & 255) / 512)
                let height = width * (0.55 + Double((seed >> 8) & 255) / 700)
                let xJitter = (Double((seed >> 16) & 255) / 255 - 0.5) * spacing * 0.5
                let yJitter = (Double((seed >> 24) & 255) / 255 - 0.5) * spacing * 0.5
                let cloudRect = MKMapRect(
                    x: Double(gridX) * spacing + xJitter,
                    y: Double(gridY) * spacing + yJitter,
                    width: width,
                    height: height
                )
                context.setFillColor(palette.highlight.uiColor.cgColor)
                context.fillEllipse(in: rect(for: cloudRect))
            }
        }
    }

    private func carveCoverage(in mapRect: MKMapRect, zoomScale: MKZoomScale, context: CGContext) {
        let visibleChunks = snapshot.chunks.values.filter { $0.key.mapRect.intersects(mapRect) }
        guard !visibleChunks.isEmpty else { return }

        context.setBlendMode(.destinationOut)
        for chunk in visibleChunks {
            draw(mask: chunk.mask, key: chunk.key, zoomScale: zoomScale, alpha: 0.28, expansion: 0.52, context: context)
            draw(mask: chunk.mask, key: chunk.key, zoomScale: zoomScale, alpha: 0.52, expansion: 0.28, context: context)
            draw(mask: chunk.mask, key: chunk.key, zoomScale: zoomScale, alpha: 1, expansion: 0.08, context: context)
        }
    }

    private func draw(
        mask: CoverageMask,
        key: CoverageChunkKey,
        zoomScale: MKZoomScale,
        alpha: CGFloat,
        expansion: CGFloat,
        context: CGContext
    ) {
        context.setFillColor(UIColor.white.withAlphaComponent(alpha).cgColor)
        let chunkOriginX = key.x * 64
        let chunkOriginY = key.y * 64

        for localY in 0..<64 {
            for localX in 0..<64 where mask.contains(localX: localX, localY: localY) {
                let cell = CoverageCell(
                    x: chunkOriginX + localX,
                    y: chunkOriginY + localY,
                    zoom: ExplorationConfiguration.streetPrecise.coverageZoom
                )
                let cellRect = rect(for: cell.mapRect)
                let side = max(max(cellRect.width, cellRect.height), 2)
                let center = CGPoint(x: cellRect.midX, y: cellRect.midY)
                let expandedSide = side * (1 + expansion * 2)
                let revealRect = CGRect(
                    x: center.x - expandedSide / 2,
                    y: center.y - expandedSide / 2,
                    width: expandedSide,
                    height: expandedSide
                )
                context.fillEllipse(in: revealRect)
            }
        }
    }

    private func stableHash(x: Int, y: Int) -> UInt64 {
        var value = UInt64(bitPattern: Int64(x &* 73_856_093))
        value ^= UInt64(bitPattern: Int64(y &* 19_349_663))
        value &*= 0x9E37_79B9_7F4A_7C15
        value ^= value >> 33
        return value
    }
}
