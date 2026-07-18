//
//  FogRenderStyleTests.swift
//  LockiTests
//
//  Created by Max Oliinyk on 18.07.2026.
//

import CoreFoundation
import Testing
@testable import Locki

@Suite("Fog render style")
struct FogRenderStyleTests {
    @Test("Dark appearance uses a darker fog tone", arguments: LockiMapStyle.allCases)
    func darkAppearance(mapStyle: LockiMapStyle) {
        let light = FogRenderStyle(
            mapStyle: mapStyle,
            interfaceStyle: .light,
            reduceTransparency: false,
            increasedContrast: false
        ).palette
        let dark = FogRenderStyle(
            mapStyle: mapStyle,
            interfaceStyle: .dark,
            reduceTransparency: false,
            increasedContrast: false
        ).palette

        #expect(dark.base.relativeLuminance < light.base.relativeLuminance)
        #expect(dark.base.alpha >= light.base.alpha)
    }

    @Test("Reduce Transparency keeps fog opaque in both appearances", arguments: FogInterfaceStyle.allCases)
    func reduceTransparency(interfaceStyle: FogInterfaceStyle) {
        let palette = FogRenderStyle(
            mapStyle: .standard,
            interfaceStyle: interfaceStyle,
            reduceTransparency: true,
            increasedContrast: false
        ).palette

        #expect(palette.base.alpha >= 0.94)
    }
}
