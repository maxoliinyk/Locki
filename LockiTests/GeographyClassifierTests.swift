//
//  GeographyClassifierTests.swift
//  LockiTests
//
//  Created by Max Oliinyk on 18.07.2026.
//

import Foundation
import Testing
@testable import Locki

@Suite("Geography classifier")
struct GeographyClassifierTests {
    private let classifier = GeographyClassifier(datasetVersion: "test-1")

    @Test("Classifies a point inside one country and city")
    func certainCountryAndCity() {
        let country = countryFeature(iso3: "AAA", polygons: [square()])
        let city = cityFeature(polygons: [square(minimum: -0.5, maximum: 0.5)])

        let result = classifier.classify(
            coordinate: GeoCoordinate(latitude: 0, longitude: 0),
            horizontalAccuracyMeters: 35,
            countries: [country],
            cities: [city]
        )

        #expect(result.status == .certain)
        #expect(result.country?.iso3 == "AAA")
        #expect(result.city?.id == 1)
        #expect(result.datasetVersion == "test-1")
    }

    @Test("Treats polygon holes as outside")
    func hole() {
        let polygon = GeographyPolygon(rings: [
            ring(minimum: -2, maximum: 2),
            ring(minimum: -0.5, maximum: 0.5),
        ])

        let result = classifier.classify(
            coordinate: GeoCoordinate(latitude: 0, longitude: 0),
            horizontalAccuracyMeters: 0,
            countries: [countryFeature(iso3: "AAA", polygons: [polygon])],
            cities: []
        )

        #expect(result.status == .outside)
        #expect(result.country == nil)
    }

    @Test("Classifies islands in a multipolygon")
    func islands() {
        let result = classifier.classify(
            coordinate: GeoCoordinate(latitude: 10, longitude: 10),
            horizontalAccuracyMeters: 10,
            countries: [countryFeature(iso3: "AAA", polygons: [square(), square(center: 10)])],
            cities: []
        )

        #expect(result.status == .certain)
        #expect(result.country?.iso3 == "AAA")
    }

    @Test("Overlapping claims remain ambiguous")
    func overlappingCountries() {
        let result = classifier.classify(
            coordinate: GeoCoordinate(latitude: 0, longitude: 0),
            horizontalAccuracyMeters: 0,
            countries: [
                countryFeature(iso3: "AAA", polygons: [square()]),
                countryFeature(iso3: "BBB", polygons: [square()]),
            ],
            cities: []
        )

        #expect(result.status == .ambiguous)
        #expect(result.country == nil)
    }

    @Test("Accuracy radius touching a border remains ambiguous")
    func accuracyUncertainty() {
        let result = classifier.classify(
            coordinate: GeoCoordinate(latitude: 0, longitude: 0.9998),
            horizontalAccuracyMeters: 35,
            countries: [countryFeature(iso3: "AAA", polygons: [square()])],
            cities: []
        )

        #expect(result.status == .ambiguous)
        #expect(result.country == nil)
    }

    @Test("Handles polygons crossing the antimeridian")
    func antimeridian() {
        let polygon = GeographyPolygon(rings: [[
            GeoCoordinate(latitude: -1, longitude: 179),
            GeoCoordinate(latitude: -1, longitude: -179),
            GeoCoordinate(latitude: 1, longitude: -179),
            GeoCoordinate(latitude: 1, longitude: 179),
            GeoCoordinate(latitude: -1, longitude: 179),
        ]])

        let result = classifier.classify(
            coordinate: GeoCoordinate(latitude: 0, longitude: 179.5),
            horizontalAccuracyMeters: 10,
            countries: [countryFeature(iso3: "AAA", polygons: [polygon])],
            cities: []
        )

        #expect(result.status == .certain)
        #expect(result.country?.iso3 == "AAA")
    }

    @Test("Bundled catalog has fixed denominator invariants")
    func catalogInvariants() async throws {
        let catalog = try GeographyCatalog()

        #expect(await catalog.datasetVersion == "2026.07.18.1")
        #expect(try await catalog.countryCount(sovereignOnly: true) == 195)
        #expect(try await catalog.cityCount() == 11_422)
    }

    @Test("Classifies a known point through the bundled R-tree catalog")
    func bundledCatalogClassification() async throws {
        let catalog = try GeographyCatalog()

        let result = try await catalog.classify(
            coordinate: GeoCoordinate(latitude: 52.52, longitude: 13.405),
            horizontalAccuracyMeters: 35
        )

        #expect(result.status == .certain)
        #expect(result.country?.iso3 == "DEU")
        #expect(result.city?.name.localizedCaseInsensitiveContains("Berlin") == true)
    }

    private func countryFeature(
        iso3: String,
        polygons: [GeographyPolygon]
    ) -> GeographyFeature<GeographyCountry> {
        GeographyFeature(
            value: GeographyCountry(
                iso2: String(iso3.prefix(2)),
                iso3: iso3,
                m49Code: "001",
                name: iso3,
                regionCode: "150",
                regionName: "Europe",
                subregionName: "Test",
                isSovereign: true
            ),
            polygons: polygons
        )
    }

    private func cityFeature(polygons: [GeographyPolygon]) -> GeographyFeature<GeographyCity> {
        GeographyFeature(
            value: GeographyCity(
                id: 1,
                name: "Test City",
                countryISO3: "AAA",
                population: 100_000,
                areaSquareKilometers: 20
            ),
            polygons: polygons
        )
    }

    private func square(center: Double = 0, minimum: Double = -1, maximum: Double = 1) -> GeographyPolygon {
        GeographyPolygon(rings: [ring(center: center, minimum: minimum, maximum: maximum)])
    }

    private func ring(center: Double = 0, minimum: Double, maximum: Double) -> [GeoCoordinate] {
        [
            GeoCoordinate(latitude: center + minimum, longitude: center + minimum),
            GeoCoordinate(latitude: center + minimum, longitude: center + maximum),
            GeoCoordinate(latitude: center + maximum, longitude: center + maximum),
            GeoCoordinate(latitude: center + maximum, longitude: center + minimum),
            GeoCoordinate(latitude: center + minimum, longitude: center + minimum),
        ]
    }
}
