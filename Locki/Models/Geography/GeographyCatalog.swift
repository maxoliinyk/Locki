//
//  GeographyCatalog.swift
//  Locki
//
//  Created by Max Oliinyk on 18.07.2026.
//

import Foundation
import SQLite3

actor GeographyCatalog {
    static let bundled: GeographyCatalog? = try? GeographyCatalog()

    let datasetVersion: String
    private let handle: GeographyDatabaseHandle
    private var database: OpaquePointer? { handle.pointer }

    init(databaseURL: URL? = nil) throws {
        let resolvedURL = try databaseURL ?? Self.bundledDatabaseURL()
        var openedDatabase: OpaquePointer?
        let result = sqlite3_open_v2(
            resolvedURL.path(percentEncoded: false),
            &openedDatabase,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
            nil
        )
        guard result == SQLITE_OK, let openedDatabase else {
            let message = openedDatabase.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
            sqlite3_close(openedDatabase)
            throw GeographyCatalogError.databaseOpenFailed(message)
        }
        handle = GeographyDatabaseHandle(pointer: openedDatabase)
        datasetVersion = try Self.metadataValue(key: "catalog_version", database: openedDatabase)
    }

    func classify(
        coordinate: GeoCoordinate,
        horizontalAccuracyMeters: Double
    ) throws -> GeographyClassification {
        let latitudeExpansion = horizontalAccuracyMeters / 111_195
        let longitudeScale = max(0.01, cos(coordinate.latitude * .pi / 180))
        let longitudeExpansion = horizontalAccuracyMeters / (111_195 * longitudeScale)
        let countries = try countryFeatures(
            coordinate: coordinate,
            latitudeExpansion: latitudeExpansion,
            longitudeExpansion: longitudeExpansion
        )
        let cities = try cityFeatures(
            coordinate: coordinate,
            latitudeExpansion: latitudeExpansion,
            longitudeExpansion: longitudeExpansion
        )
        return GeographyClassifier(datasetVersion: datasetVersion).classify(
            coordinate: coordinate,
            horizontalAccuracyMeters: horizontalAccuracyMeters,
            countries: countries,
            cities: cities
        )
    }

    func countryCount(sovereignOnly: Bool = false) throws -> Int {
        try scalarInt(
            sovereignOnly
                ? "SELECT count(*) FROM countries WHERE is_sovereign = 1"
                : "SELECT count(*) FROM countries"
        )
    }

    func cityCount() throws -> Int {
        try scalarInt("SELECT count(*) FROM cities")
    }

    private static func bundledDatabaseURL() throws -> URL {
        if let url = Bundle.main.url(
            forResource: "LockiGeography",
            withExtension: "sqlite",
            subdirectory: "Geography"
        ) ?? Bundle.main.url(forResource: "LockiGeography", withExtension: "sqlite") {
            return url
        }
        throw GeographyCatalogError.resourceUnavailable
    }

    private static func metadataValue(key: String, database: OpaquePointer) throws -> String {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT value FROM metadata WHERE key = ?", -1, &statement, nil) == SQLITE_OK else {
            throw GeographyCatalogError.databaseQueryFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else {
            throw GeographyCatalogError.databaseQueryFailed("Missing metadata value: \(key)")
        }
        return String(cString: text)
    }

    private func countryFeatures(
        coordinate: GeoCoordinate,
        latitudeExpansion: Double,
        longitudeExpansion: Double
    ) throws -> [GeographyFeature<GeographyCountry>] {
        let query = """
            SELECT c.iso2, c.iso3, c.m49, c.name, c.region_code, c.region_name,
                   c.subregion_name, c.is_sovereign, c.geometry
            FROM country_rtree r JOIN countries c ON c.id = r.id
            WHERE r.min_lon <= ? AND r.max_lon >= ? AND r.min_lat <= ? AND r.max_lat >= ?
            """
        return try rows(
            query: query,
            coordinate: coordinate,
            latitudeExpansion: latitudeExpansion,
            longitudeExpansion: longitudeExpansion
        ) { statement in
            let country = GeographyCountry(
                iso2: Self.text(statement, 0),
                iso3: Self.text(statement, 1),
                m49Code: Self.text(statement, 2),
                name: Self.text(statement, 3),
                regionCode: Self.text(statement, 4),
                regionName: Self.text(statement, 5),
                subregionName: Self.text(statement, 6),
                isSovereign: sqlite3_column_int(statement, 7) == 1
            )
            return GeographyFeature(value: country, polygons: try Self.geometry(statement, column: 8))
        }
    }

    private func cityFeatures(
        coordinate: GeoCoordinate,
        latitudeExpansion: Double,
        longitudeExpansion: Double
    ) throws -> [GeographyFeature<GeographyCity>] {
        let query = """
            SELECT c.id, c.name, c.country_iso3, c.population, c.area_square_km, c.geometry
            FROM city_rtree r JOIN cities c ON c.id = r.id
            WHERE r.min_lon <= ? AND r.max_lon >= ? AND r.min_lat <= ? AND r.max_lat >= ?
            """
        return try rows(
            query: query,
            coordinate: coordinate,
            latitudeExpansion: latitudeExpansion,
            longitudeExpansion: longitudeExpansion
        ) { statement in
            let city = GeographyCity(
                id: Int(sqlite3_column_int64(statement, 0)),
                name: Self.text(statement, 1),
                countryISO3: Self.text(statement, 2),
                population: Int(sqlite3_column_int64(statement, 3)),
                areaSquareKilometers: Int(sqlite3_column_int64(statement, 4))
            )
            return GeographyFeature(value: city, polygons: try Self.geometry(statement, column: 5))
        }
    }

    private func rows<Value>(
        query: String,
        coordinate: GeoCoordinate,
        latitudeExpansion: Double,
        longitudeExpansion: Double,
        transform: (OpaquePointer) throws -> Value
    ) throws -> [Value] {
        guard let database else { throw GeographyCatalogError.databaseQueryFailed("Catalog closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw GeographyCatalogError.databaseQueryFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, coordinate.longitude + longitudeExpansion)
        sqlite3_bind_double(statement, 2, coordinate.longitude - longitudeExpansion)
        sqlite3_bind_double(statement, 3, coordinate.latitude + latitudeExpansion)
        sqlite3_bind_double(statement, 4, coordinate.latitude - latitudeExpansion)
        var values: [Value] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                values.append(try transform(statement))
            case SQLITE_DONE:
                return values
            default:
                throw GeographyCatalogError.databaseQueryFailed(String(cString: sqlite3_errmsg(database)))
            }
        }
    }

    private func scalarInt(_ query: String) throws -> Int {
        guard let database else { throw GeographyCatalogError.databaseQueryFailed("Catalog closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw GeographyCatalogError.databaseQueryFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw GeographyCatalogError.databaseQueryFailed(String(cString: sqlite3_errmsg(database)))
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    private static func geometry(_ statement: OpaquePointer, column: Int32) throws -> [GeographyPolygon] {
        guard let bytes = sqlite3_column_blob(statement, column) else {
            throw GeographyCatalogError.invalidGeometry
        }
        let count = Int(sqlite3_column_bytes(statement, column))
        let compressed = Data(bytes: bytes, count: count)
        var decoder = GeographyWKBDecoder(data: try decompressed(compressed))
        return try decoder.decode()
    }

    private static func decompressed(_ data: Data) throws -> Data {
        guard data.count >= MemoryLayout<UInt32>.size else {
            throw GeographyCatalogError.invalidGeometry
        }
        let expectedCount = data.withUnsafeBytes { buffer in
            Int(UInt32(littleEndian: buffer.loadUnaligned(as: UInt32.self)))
        }
        guard expectedCount > 0 else { throw GeographyCatalogError.invalidGeometry }
        let payload = data.dropFirst(MemoryLayout<UInt32>.size)
        let output: Data
        do {
            output = try (Data(payload) as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw GeographyCatalogError.invalidGeometry
        }
        guard output.count == expectedCount else { throw GeographyCatalogError.invalidGeometry }
        return output
    }
}

private nonisolated final class GeographyDatabaseHandle: @unchecked Sendable {
    let pointer: OpaquePointer?

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        sqlite3_close(pointer)
    }
}

private nonisolated let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private nonisolated struct GeographyWKBDecoder {
    let data: Data
    private var offset = 0

    init(data: Data) {
        self.data = data
    }

    mutating func decode() throws -> [GeographyPolygon] {
        let byteOrder = try readUInt8()
        guard byteOrder == 1 else { throw GeographyCatalogError.invalidGeometry }
        let type = try readUInt32()
        switch type {
        case 1003:
            return [try readPolygonBody()]
        case 1006:
            let count = try readCount()
            return try (0..<count).map { _ in
                guard try readUInt8() == 1, try readUInt32() == 1003 else {
                    throw GeographyCatalogError.invalidGeometry
                }
                return try readPolygonBody()
            }
        default:
            throw GeographyCatalogError.invalidGeometry
        }
    }

    private mutating func readPolygonBody() throws -> GeographyPolygon {
        let ringCount = try readCount()
        let rings = try (0..<ringCount).map { _ in
            let pointCount = try readCount()
            return try (0..<pointCount).map { _ in try readCoordinate() }
        }
        return GeographyPolygon(rings: rings)
    }

    private mutating func readCoordinate() throws -> GeoCoordinate {
        let longitude = Double(try readInt32()) / 1_000_000
        let latitude = Double(try readInt32()) / 1_000_000
        return GeoCoordinate(latitude: latitude, longitude: longitude)
    }

    private mutating func readCount() throws -> Int {
        let value = try readUInt32()
        guard value <= 10_000_000 else { throw GeographyCatalogError.invalidGeometry }
        return Int(value)
    }

    private mutating func readUInt8() throws -> UInt8 {
        guard offset < data.count else { throw GeographyCatalogError.invalidGeometry }
        defer { offset += 1 }
        return data[offset]
    }

    private mutating func readUInt32() throws -> UInt32 {
        try readValue(UInt32.self)
    }

    private mutating func readInt32() throws -> Int32 {
        try readValue(Int32.self)
    }

    private mutating func readValue<Value>(_ type: Value.Type) throws -> Value {
        let size = MemoryLayout<Value>.size
        guard offset + size <= data.count else { throw GeographyCatalogError.invalidGeometry }
        let value = data.withUnsafeBytes { rawBuffer in
            rawBuffer.loadUnaligned(fromByteOffset: offset, as: Value.self)
        }
        offset += size
        return value
    }
}
