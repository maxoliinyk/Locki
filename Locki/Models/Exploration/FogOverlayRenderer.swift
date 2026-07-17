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

nonisolated struct FogRenderStyle: Equatable {
    let mapStyle: LockiMapStyle
    let reduceTransparency: Bool
    let increasedContrast: Bool
}

nonisolated final class FogOverlayRenderer: MKOverlayRenderer {
    private var snapshot: CoverageSnapshot = .empty
    private var style = FogRenderStyle(
        mapStyle: .standard,
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
        let palette = fogPalette
        context.setBlendMode(.normal)
        context.setFillColor(palette.base.cgColor)
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
                context.setFillColor(palette.highlight.cgColor)
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

    private var fogPalette: (base: UIColor, highlight: UIColor) {
        let contrastBoost = style.increasedContrast ? 0.1 : 0
        switch style.mapStyle {
        case .standard:
            return (
                UIColor(red: 0.58 - contrastBoost, green: 0.66 - contrastBoost, blue: 0.64 - contrastBoost, alpha: style.reduceTransparency ? 0.94 : 0.76),
                UIColor(white: 1, alpha: 0.035)
            )
        case .imagery:
            return (
                UIColor(red: 0.34 - contrastBoost, green: 0.39 - contrastBoost, blue: 0.38 - contrastBoost, alpha: style.reduceTransparency ? 0.96 : 0.82),
                UIColor(white: 1, alpha: 0.045)
            )
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
