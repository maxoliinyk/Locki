#!/usr/bin/env python3
"""Build Locki's deterministic, read-only geography catalog.

Raw source archives stay outside Git. The normalized geoBoundaries/M49 manifests,
source checksums, and generated SQLite database are committed for reproducibility.
Only Python's standard library is required.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import html.parser
import json
import math
import sqlite3
import struct
import sys
import urllib.request
import zipfile
import zlib
from pathlib import Path
from typing import Iterable, Iterator, Sequence


ROOT = Path(__file__).resolve().parents[2]
TOOL_DIR = Path(__file__).resolve().parent
SOURCE_RECORDS = TOOL_DIR / "source-records.json"
OUTPUT = ROOT / "Locki/Resources/Geography/LockiGeography.sqlite"

CATALOG_VERSION = "2026.07.18.1"
GEODATA_API_URL = "https://www.geoboundaries.org/api/current/gbOpen/ALL/ADM0/"
GEODATA_API_SHA256 = "98de5b1034e3a016e652b7afd2b739dae309acec8f890b7394417d62fef99ea3"
M49_URL = "https://unstats.un.org/unsd/methodology/m49/overview/"
M49_SHA256 = "748f6ff7380c8a50ea9448f068b79e3a1ee31be63207249e8cc89bf1eb969d11"
GHSL_URL = (
    "https://jeodpp.jrc.ec.europa.eu/ftp/jrc-opendata/GHSL/"
    "GHS_UCDB_GLOBE_R2024A/GHS_UCDB_GLOBE_R2024A/V1-2/"
    "GHS_UCDB_GLOBE_R2024A_V1_2.zip"
)
GHSL_SHA256 = "12dc8d366a6057b832a070ba3f7b7b7c601bad191da0417a666851f35f10db2e"

SOVEREIGN_ISO3 = frozenset(
    """AFG ALB DZA AND AGO ATG ARG ARM AUS AUT AZE BHS BHR BGD BRB BLR BEL
    BLZ BEN BTN BOL BIH BWA BRA BRN BGR BFA BDI CPV KHM CMR CAN CAF TCD CHL
    CHN COL COM COG COD CRI CIV HRV CUB CYP CZE DNK DJI DMA DOM ECU EGY SLV
    GNQ ERI EST SWZ ETH FJI FIN FRA GAB GMB GEO DEU GHA GRC GRD GTM GIN GNB
    GUY HTI HND HUN ISL IND IDN IRN IRQ IRL ISR ITA JAM JPN JOR KAZ KEN KIR
    PRK KOR KWT KGZ LAO LVA LBN LSO LBR LBY LIE LTU LUX MDG MWI MYS MDV MLI
    MLT MHL MRT MUS MEX FSM MDA MCO MNG MNE MAR MOZ MMR NAM NRU NPL NLD NZL
    NIC NER NGA MKD NOR OMN PAK PLW PAN PNG PRY PER PHL POL PRT QAT ROU RUS
    RWA KNA LCA VCT WSM SMR STP SAU SEN SRB SYC SLE SGP SVK SVN SLB SOM ZAF
    SSD ESP LKA SDN SUR SWE CHE SYR TJK TZA THA TLS TGO TON TTO TUN TUR TKM
    TUV UGA UKR ARE GBR USA URY UZB VUT VAT VEN VNM YEM ZMB ZWE PSE""".split()
)

# UN M49 does not assign ISO codes to these two gbOpen ADM0 datasets. Reserved
# local M49 identifiers keep them visible while excluding them from sovereign
# completion denominators.
CUSTOM_AREA_RECORDS = {
    "TWN": {
        "iso2": "TW", "iso3": "TWN", "m49": "901", "name": "Taiwan",
        "region_code": "142", "region_name": "Asia", "subregion_name": "Eastern Asia",
        "is_sovereign": False,
    },
    "XKX": {
        "iso2": "XK", "iso3": "XKX", "m49": "902", "name": "Kosovo",
        "region_code": "150", "region_name": "Europe", "subregion_name": "Southern Europe",
        "is_sovereign": False,
    },
}

M49_COLUMNS = (
    "global_code",
    "global_name",
    "region_code",
    "region_name",
    "subregion_code",
    "subregion_name",
    "intermediate_region_code",
    "intermediate_region_name",
    "name",
    "m49",
    "iso2",
    "iso3",
    "ldc",
    "lldc",
    "sids",
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download(url: str, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    request = urllib.request.Request(url, headers={"User-Agent": "Locki geography generator"})
    with urllib.request.urlopen(request) as response, destination.open("wb") as output:
        while chunk := response.read(1024 * 1024):
            output.write(chunk)


def require_checksum(path: Path, expected: str) -> None:
    actual = sha256(path)
    if expected and actual != expected:
        raise RuntimeError(f"checksum mismatch for {path}: expected {expected}, got {actual}")


class M49Parser(html.parser.HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.in_english_table = False
        self.in_body = False
        self.in_cell = False
        self.current_cell: list[str] = []
        self.current_row: list[str] = []
        self.rows: list[list[str]] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attributes = dict(attrs)
        if tag == "table" and attributes.get("id") == "downloadTableEN":
            self.in_english_table = True
        elif self.in_english_table and tag == "tbody":
            self.in_body = True
        elif self.in_body and tag == "tr":
            self.current_row = []
        elif self.in_body and tag == "td":
            self.in_cell = True
            self.current_cell = []

    def handle_endtag(self, tag: str) -> None:
        if self.in_cell and tag == "td":
            self.current_row.append(" ".join("".join(self.current_cell).split()))
            self.in_cell = False
        elif self.in_body and tag == "tr":
            if len(self.current_row) == len(M49_COLUMNS):
                self.rows.append(self.current_row)
        elif self.in_english_table and tag == "tbody":
            self.in_body = False
        elif self.in_english_table and tag == "table":
            self.in_english_table = False

    def handle_data(self, data: str) -> None:
        if self.in_cell:
            self.current_cell.append(data)


def parse_m49(path: Path) -> list[dict[str, object]]:
    parser = M49Parser()
    parser.feed(path.read_text(encoding="utf-8"))
    records = [dict(zip(M49_COLUMNS, row, strict=True)) for row in parser.rows]
    if len(records) < 240:
        raise RuntimeError(f"expected at least 240 M49 records, found {len(records)}")
    for record in records:
        record["is_sovereign"] = record["iso3"] in SOVEREIGN_ISO3
    sovereign_count = sum(bool(record["is_sovereign"]) for record in records)
    if sovereign_count != 195:
        raise RuntimeError(f"expected 195 sovereign records, found {sovereign_count}")
    return records


def bootstrap_records(source_dir: Path) -> None:
    api_path = source_dir / "geoboundaries-adm0.json"
    m49_path = source_dir / "m49-overview.html"
    if not api_path.exists():
        download(GEODATA_API_URL, api_path)
    if not m49_path.exists():
        download(M49_URL, m49_path)
    require_checksum(api_path, GEODATA_API_SHA256)
    if M49_SHA256:
        require_checksum(m49_path, M49_SHA256)

    boundaries = json.loads(api_path.read_text(encoding="utf-8"))
    present_iso3 = {boundary["boundaryISO"] for boundary in boundaries}
    required_boundaries = SOVEREIGN_ISO3 | CUSTOM_AREA_RECORDS.keys()
    for iso3 in sorted(required_boundaries - present_iso3):
        with urllib.request.urlopen(
            urllib.request.Request(
                f"https://www.geoboundaries.org/api/current/gbOpen/{iso3}/ADM0/",
                headers={"User-Agent": "Locki geography generator"},
            )
        ) as response:
            boundaries.append(json.load(response))
    def prepare_boundary(boundary: dict[str, object]) -> dict[str, str]:
        url = boundary["gjDownloadURL"]
        iso3 = boundary["boundaryISO"]
        destination = source_dir / "boundaries-full" / f"{iso3}.geojson"
        if not destination.exists():
            download(url, destination)
        return {
            "iso3": iso3,
            "name": boundary["boundaryName"],
            "boundary_id": boundary["boundaryID"],
            "year": str(boundary["boundaryYearRepresented"]),
            "source": boundary["boundarySource"],
            "license": boundary["boundaryLicense"],
            "url": url,
            "sha256": sha256(destination),
        }

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
        normalized_boundaries = list(executor.map(prepare_boundary, boundaries))

    payload = {
        "catalog_version": CATALOG_VERSION,
        "sources": {
            "geoboundaries": {
                "api_url": GEODATA_API_URL,
                "api_sha256": GEODATA_API_SHA256,
                "license": "CC BY 4.0",
                "records": sorted(normalized_boundaries, key=lambda item: item["iso3"]),
            },
            "m49": {
                "url": M49_URL,
                "sha256": sha256(m49_path),
                "records": parse_m49(m49_path),
            },
            "ghsl": {
                "url": GHSL_URL,
                "sha256": GHSL_SHA256,
                "release": "GHS-UCDB R2024A V1.2 (2025 fixed delineation)",
                "license": "CC BY 4.0",
            },
        },
    }
    SOURCE_RECORDS.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def prepare_sources(source_dir: Path) -> tuple[Path, dict[str, object]]:
    records = json.loads(SOURCE_RECORDS.read_text(encoding="utf-8"))
    for boundary in records["sources"]["geoboundaries"]["records"]:
        destination = source_dir / "boundaries-full" / f"{boundary['iso3']}.geojson"
        if not destination.exists():
            download(boundary["url"], destination)
        require_checksum(destination, boundary["sha256"])

    ghsl_zip = source_dir / "GHS_UCDB_GLOBE_R2024A_V1_2.zip"
    if not ghsl_zip.exists():
        download(records["sources"]["ghsl"]["url"], ghsl_zip)
    require_checksum(ghsl_zip, records["sources"]["ghsl"]["sha256"])
    return ghsl_zip, records


def gpkg_wkb(blob: bytes) -> bytes:
    if len(blob) < 8 or blob[:2] != b"GP":
        raise ValueError("invalid GeoPackage geometry")
    flags = blob[3]
    envelope_code = (flags >> 1) & 0b111
    envelope_sizes = {0: 0, 1: 32, 2: 48, 3: 48, 4: 64}
    if envelope_code not in envelope_sizes:
        raise ValueError("unsupported GeoPackage envelope")
    return blob[8 + envelope_sizes[envelope_code] :]


def read_uint32(data: bytes, offset: int, endian: str) -> tuple[int, int]:
    return struct.unpack_from(endian + "I", data, offset)[0], offset + 4


def read_double(data: bytes, offset: int, endian: str) -> tuple[float, int]:
    return struct.unpack_from(endian + "d", data, offset)[0], offset + 8


def parse_wkb_geometry(data: bytes, offset: int = 0) -> tuple[list[list[list[tuple[float, float]]]], int]:
    endian = "<" if data[offset] == 1 else ">"
    offset += 1
    geometry_type, offset = read_uint32(data, offset, endian)
    base_type = geometry_type % 1000
    if base_type == 3:
        ring_count, offset = read_uint32(data, offset, endian)
        polygon: list[list[tuple[float, float]]] = []
        for _ in range(ring_count):
            point_count, offset = read_uint32(data, offset, endian)
            ring = []
            for _ in range(point_count):
                x, offset = read_double(data, offset, endian)
                y, offset = read_double(data, offset, endian)
                ring.append((x, y))
            polygon.append(ring)
        return [polygon], offset
    if base_type == 6:
        polygon_count, offset = read_uint32(data, offset, endian)
        polygons = []
        for _ in range(polygon_count):
            child, offset = parse_wkb_geometry(data, offset)
            polygons.extend(child)
        return polygons, offset
    raise ValueError(f"unsupported WKB geometry type {geometry_type}")


def inverse_mollweide(x: float, y: float) -> tuple[float, float]:
    radius = 6_378_137.0
    theta = math.asin(max(-1.0, min(1.0, y / (math.sqrt(2.0) * radius))))
    latitude = math.asin(max(-1.0, min(1.0, (2 * theta + math.sin(2 * theta)) / math.pi)))
    denominator = 2 * math.sqrt(2.0) * radius * math.cos(theta)
    longitude = 0.0 if abs(denominator) < 1e-12 else math.pi * x / denominator
    return math.degrees(longitude), math.degrees(latitude)


def transform_ghsl(polygons: list[list[list[tuple[float, float]]]]) -> list[list[list[tuple[float, float]]]]:
    return [
        [[inverse_mollweide(x, y) for x, y in ring] for ring in polygon]
        for polygon in polygons
    ]


def geometry_from_geojson(value: dict[str, object]) -> list[list[list[tuple[float, float]]]]:
    geometry_type = value["type"]
    coordinates = value["coordinates"]
    if geometry_type == "Polygon":
        coordinates = [coordinates]
    elif geometry_type != "MultiPolygon":
        raise ValueError(f"unsupported GeoJSON geometry {geometry_type}")
    return [
        [[(float(point[0]), float(point[1])) for point in ring] for ring in polygon]
        for polygon in coordinates
    ]


def write_geometry_blob(polygons: Sequence[Sequence[Sequence[tuple[float, float]]]]) -> bytes:
    output = bytearray(struct.pack("<BI", 1, 1006))
    output.extend(struct.pack("<I", len(polygons)))
    for polygon in polygons:
        output.extend(struct.pack("<BI", 1, 1003))
        output.extend(struct.pack("<I", len(polygon)))
        for ring in polygon:
            output.extend(struct.pack("<I", len(ring)))
            for longitude, latitude in ring:
                output.extend(
                    struct.pack(
                        "<ii",
                        round(longitude * 1_000_000),
                        round(latitude * 1_000_000),
                    )
                )
    raw = bytes(output)
    compressor = zlib.compressobj(level=9, wbits=-zlib.MAX_WBITS)
    compressed = compressor.compress(raw) + compressor.flush()
    return struct.pack("<I", len(raw)) + compressed


def bounds(polygons: Sequence[Sequence[Sequence[tuple[float, float]]]]) -> tuple[float, float, float, float]:
    points = [point for polygon in polygons for ring in polygon for point in ring]
    if not points:
        raise ValueError("empty geometry")
    longitudes = [point[0] for point in points]
    latitudes = [point[1] for point in points]
    return min(longitudes), max(longitudes), min(latitudes), max(latitudes)


def validate_polygon_rings(
    polygons: Sequence[Sequence[Sequence[tuple[float, float]]]],
    identifier: str,
) -> None:
    if not polygons:
        raise ValueError(f"empty geometry for {identifier}")
    for polygon in polygons:
        if not polygon:
            raise ValueError(f"polygon without rings for {identifier}")
        for ring in polygon:
            if len(ring) < 4 or ring[0] != ring[-1]:
                raise ValueError(f"invalid or unclosed ring for {identifier}")
            if any(
                not math.isfinite(longitude)
                or not math.isfinite(latitude)
                or not -180 <= longitude <= 180
                or not -90 <= latitude <= 90
                for longitude, latitude in ring
            ):
                raise ValueError(f"coordinate out of WGS84 bounds for {identifier}")


def normalized_name(value: str) -> str:
    # GHSL's country-name column contains a small number of UTF-8 strings that
    # were decoded as Latin-1 in the source GeoPackage.
    if "Ã" in value or "Â" in value:
        try:
            value = value.encode("latin-1").decode("utf-8")
        except UnicodeError:
            pass
    return "".join(character.casefold() for character in value if character.isalnum())


COUNTRY_NAME_ALIASES = {
    "boliviaplurinationalstateof": "BOL",
    "bruneidarussalam": "BRN",
    "cotedivoire": "CIV",
    "democraticpeoplesrepublicofkorea": "PRK",
    "dempeoplesrepublicofkorea": "PRK",
    "democraticrepublicofthecongo": "COD",
    "iranislamicrepublicof": "IRN",
    "laopeoplesdemocraticrepublic": "LAO",
    "micronesiafederatedstatesof": "FSM",
    "republicofkorea": "KOR",
    "chinataiwanprovinceofchina": "TWN",
    "kosovounderunscres1244": "XKX",
    "netherlands": "NLD",
    "republicofmoldova": "MDA",
    "russianfederation": "RUS",
    "stateofpalestine": "PSE",
    "syrianarabrepublic": "SYR",
    "theformer" + "yugoslavrepublicofmacedonia": "MKD",
    "unitedrepublicoftanzania": "TZA",
    "unitedstatesofamerica": "USA",
    "unitedkingdom": "GBR",
    "turkey": "TUR",
    "venezuela" + "bolivarianrepublicof": "VEN",
    "vietnam": "VNM",
}


def create_schema(connection: sqlite3.Connection) -> None:
    connection.executescript(
        """
        PRAGMA journal_mode = OFF;
        PRAGMA synchronous = OFF;
        PRAGMA page_size = 4096;
        CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
        CREATE TABLE countries (
            id INTEGER PRIMARY KEY,
            iso2 TEXT NOT NULL UNIQUE,
            iso3 TEXT NOT NULL UNIQUE,
            m49 TEXT NOT NULL UNIQUE,
            name TEXT NOT NULL,
            region_code TEXT NOT NULL,
            region_name TEXT NOT NULL,
            subregion_name TEXT NOT NULL,
            is_sovereign INTEGER NOT NULL,
            geometry BLOB
        );
        CREATE VIRTUAL TABLE country_rtree USING rtree(id, min_lon, max_lon, min_lat, max_lat);
        CREATE TABLE cities (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            country_iso3 TEXT NOT NULL,
            population INTEGER NOT NULL,
            area_square_km INTEGER NOT NULL,
            geometry BLOB NOT NULL
        );
        CREATE INDEX cities_country ON cities(country_iso3);
        CREATE VIRTUAL TABLE city_rtree USING rtree(id, min_lon, max_lon, min_lat, max_lat);
        """
    )


def load_countries(
    connection: sqlite3.Connection,
    source_dir: Path,
    records: dict[str, object],
) -> dict[str, dict[str, object]]:
    m49_by_iso3 = {
        record["iso3"]: record
        for record in records["sources"]["m49"]["records"]
        if record["iso3"]
    }
    m49_by_iso3.update(CUSTOM_AREA_RECORDS)
    boundary_records = records["sources"]["geoboundaries"]["records"]
    boundaries_by_iso3 = {record["iso3"]: record for record in boundary_records}
    country_id = 0
    loaded: dict[str, dict[str, object]] = {}
    for iso3, m49 in sorted(m49_by_iso3.items()):
        boundary = boundaries_by_iso3.get(iso3)
        geometry = None
        geometry_bounds = None
        if boundary is not None:
            geojson = json.loads((source_dir / "boundaries-full" / f"{iso3}.geojson").read_text(encoding="utf-8"))
            features = geojson.get("features", [])
            if features:
                polygons = geometry_from_geojson(features[0]["geometry"])
                validate_polygon_rings(polygons, iso3)
                geometry = write_geometry_blob(polygons)
                geometry_bounds = bounds(polygons)
        country_id += 1
        connection.execute(
            "INSERT INTO countries VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                country_id,
                m49["iso2"],
                iso3,
                m49["m49"],
                m49["name"],
                m49["region_code"],
                m49["region_name"],
                m49["subregion_name"],
                int(bool(m49["is_sovereign"])),
                geometry,
            ),
        )
        if geometry_bounds is not None:
            min_lon, max_lon, min_lat, max_lat = geometry_bounds
            connection.execute(
                "INSERT INTO country_rtree VALUES (?, ?, ?, ?, ?)",
                (country_id, min_lon, max_lon, min_lat, max_lat),
            )
        loaded[iso3] = m49
    sovereign_count = sum(bool(record["is_sovereign"]) for record in loaded.values())
    sovereign_boundaries = SOVEREIGN_ISO3 & boundaries_by_iso3.keys()
    if sovereign_count != 195 or len(sovereign_boundaries) != 195:
        missing = sorted(SOVEREIGN_ISO3 - sovereign_boundaries)
        raise RuntimeError(f"expected 195 sovereign boundaries; missing {missing}")
    return loaded


def country_name_lookup(countries: dict[str, dict[str, object]]) -> dict[str, str]:
    lookup = {normalized_name(str(record["name"])): iso3 for iso3, record in countries.items()}
    lookup.update(COUNTRY_NAME_ALIASES)
    return lookup


def load_cities(
    connection: sqlite3.Connection,
    ghsl_zip: Path,
    countries: dict[str, dict[str, object]],
    source_dir: Path,
) -> None:
    gpkg = source_dir / "GHS_UCDB_GLOBE_R2024A.gpkg"
    if not gpkg.exists():
        with zipfile.ZipFile(ghsl_zip) as archive:
            with archive.open("GHS_UCDB_GLOBE_R2024A.gpkg") as source, gpkg.open("wb") as output:
                while chunk := source.read(1024 * 1024):
                    output.write(chunk)

    source = sqlite3.connect(f"file:{gpkg}?mode=ro", uri=True)
    table = "GHSL_UCDB_THEME_GENERAL_CHARACTERISTICS_GLOBE_R2024A"
    rows = source.execute(
        f'''SELECT ID_UC_G0, GC_UCN_MAI_2025, GC_CNT_UNN_2025,
                   GC_UCA_KM2_2025, GC_POP_TOT_2025, geom
            FROM "{table}" ORDER BY ID_UC_G0'''
    )
    names = country_name_lookup(countries)
    count = 0
    unmatched: set[str] = set()
    for city_id, name, country_name, area, population, geometry in rows:
        iso3 = names.get(normalized_name(country_name or ""))
        if iso3 is None:
            unmatched.add(country_name or "")
            continue
        polygons, consumed = parse_wkb_geometry(gpkg_wkb(geometry))
        if consumed <= 0:
            raise RuntimeError(f"failed to read city geometry {city_id}")
        transformed = transform_ghsl(polygons)
        validate_polygon_rings(transformed, f"urban centre {city_id}")
        min_lon, max_lon, min_lat, max_lat = bounds(transformed)
        connection.execute(
            "INSERT INTO cities VALUES (?, ?, ?, ?, ?, ?)",
            (
                int(city_id),
                name or f"Urban centre {city_id}",
                iso3,
                max(0, int(round(population or 0))),
                max(0, int(area or 0)),
                write_geometry_blob(transformed),
            ),
        )
        connection.execute(
            "INSERT INTO city_rtree VALUES (?, ?, ?, ?, ?)",
            (int(city_id), min_lon, max_lon, min_lat, max_lat),
        )
        count += 1
    source.close()
    if unmatched or count != 11_422:
        raise RuntimeError(f"expected 11,422 cities, loaded {count}; unmatched countries: {sorted(unmatched)}")


def build(source_dir: Path, output: Path) -> None:
    ghsl_zip, records = prepare_sources(source_dir)
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(".sqlite.tmp")
    temporary.unlink(missing_ok=True)
    connection = sqlite3.connect(temporary)
    create_schema(connection)
    connection.executemany(
        "INSERT INTO metadata VALUES (?, ?)",
        (
            ("catalog_version", CATALOG_VERSION),
            ("geoboundaries_release", "gbOpen commit 9469f09"),
            ("ghsl_release", "GHS-UCDB R2024A V1.2"),
            ("m49_source_sha256", records["sources"]["m49"]["sha256"]),
            ("geometry_encoding", "locki-int32-e6-zlib-v1"),
        ),
    )
    countries = load_countries(connection, source_dir, records)
    load_cities(connection, ghsl_zip, countries, source_dir)
    connection.commit()
    connection.execute("ANALYZE")
    connection.execute("VACUUM")
    connection.close()
    temporary.replace(output)
    print(f"wrote {output} ({output.stat().st_size:,} bytes, sha256 {sha256(output)})")


def validate(path: Path) -> None:
    connection = sqlite3.connect(f"file:{path}?mode=ro&immutable=1", uri=True)
    integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
    sovereign = connection.execute("SELECT count(*) FROM countries WHERE is_sovereign = 1").fetchone()[0]
    cities = connection.execute("SELECT count(*) FROM cities").fetchone()[0]
    duplicate_city_ids = connection.execute(
        "SELECT count(*) - count(DISTINCT id) FROM cities"
    ).fetchone()[0]
    missing_regions = connection.execute(
        "SELECT count(*) FROM countries WHERE is_sovereign = 1 AND (region_code = '' OR region_name = '')"
    ).fetchone()[0]
    connection.close()
    if (integrity, sovereign, cities, duplicate_city_ids, missing_regions) != ("ok", 195, 11_422, 0, 0):
        raise RuntimeError(
            "catalog validation failed: "
            f"integrity={integrity}, sovereign={sovereign}, cities={cities}, "
            f"duplicate_city_ids={duplicate_city_ids}, missing_regions={missing_regions}"
        )
    print(f"validated {path}: 195 sovereign countries, 11,422 cities")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-dir", type=Path, default=Path("/tmp/LockiGeographySources"))
    parser.add_argument("--output", type=Path, default=OUTPUT)
    parser.add_argument("--bootstrap-records", action="store_true")
    parser.add_argument("--validate-only", action="store_true")
    arguments = parser.parse_args()

    if arguments.bootstrap_records:
        bootstrap_records(arguments.source_dir)
    elif arguments.validate_only:
        validate(arguments.output)
    else:
        build(arguments.source_dir, arguments.output)
        validate(arguments.output)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
