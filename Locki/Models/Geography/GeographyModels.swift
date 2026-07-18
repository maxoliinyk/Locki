//
//  GeographyModels.swift
//  Locki
//
//  Created by Max Oliinyk on 18.07.2026.
//

import Foundation

nonisolated enum GeographyClassificationStatus: String, Codable, Hashable, Sendable {
    case certain
    case ambiguous
    case outside
}
nonisolated struct GeographyCountry: Codable, Hashable, Identifiable, Sendable {
    var id: String { iso3 }

    let iso2: String
    let iso3: String
    let m49Code: String
    let name: String
    let regionCode: String
    let regionName: String
    let subregionName: String
    let isSovereign: Bool
}

nonisolated struct GeographyCity: Codable, Hashable, Identifiable, Sendable {
    let id: Int
    let name: String
    let countryISO3: String
    let population: Int
    let areaSquareKilometers: Int
}

nonisolated struct GeographyClassification: Hashable, Sendable {
    let country: GeographyCountry?
    let city: GeographyCity?
    let datasetVersion: String
    let status: GeographyClassificationStatus
}

nonisolated enum GeographyCatalogError: Error, Equatable {
    case resourceUnavailable
    case databaseOpenFailed(String)
    case databaseQueryFailed(String)
    case invalidGeometry
}
