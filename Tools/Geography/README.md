# Geography catalog

`generate_catalog.py` produces Locki's bundled, read-only geography database
using only Python's standard library.

```bash
python3 Tools/Geography/generate_catalog.py \
  --source-dir /tmp/LockiGeographySources
python3 Tools/Geography/generate_catalog.py --validate-only
```

The committed `source-records.json` pins URLs, checksums, normalized UN M49
metadata, and attribution for every input boundary. Full-resolution gbOpen
geometry preserves the precision needed for Locki's 35 m accepted-accuracy
threshold. Coordinates are quantized to one-millionth of a degree (about 11 cm
latitude resolution) and deterministically zlib-compressed inside SQLite to
keep the bundled resource compact. Raw downloads remain outside Git.
`--bootstrap-records` is only for
intentionally adopting a new upstream geoBoundaries/M49 release; review and
update the pinned constants first.

Sources:

- geoBoundaries `gbOpen` ADM0, CC BY 4.0.
- United Nations M49 country and geographic-region classification.
- European Commission GHSL GHS-UCDB R2024A V1.2, CC BY 4.0.
