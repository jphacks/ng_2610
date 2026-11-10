"""Build the bundled notification catalogs from the JMA GIS ZIPs and tables.

Usage: python scripts/build-notification-regions.py INPUT_DIR OUTPUT_DIR
INPUT_DIR contains quake.zip, city.zip, tsunami.zip, shindo.html, tsunami.pdf.
Requires pyshp (<3), shapely and pdfplumber. See docs/notification-region-data.md.
"""
import html
import io
import json
import re
import sys
import unicodedata
import zipfile
import zlib
from collections import defaultdict
from pathlib import Path

import pdfplumber
import shapefile
from shapely.geometry import shape

source, output = map(Path, sys.argv[1:])


def text(value):
    return re.sub(r"\s+", "", unicodedata.normalize("NFKC", value))


def reader(name, geometry=True):
    with zipfile.ZipFile(source / f"{name}.zip") as archive:
        fields = ("dbf", "shp", "shx") if geometry else ("dbf",)
        files = {field: io.BytesIO(archive.read(next(n for n in archive.namelist() if n.endswith("." + field))))
                 for field in fields}
    return shapefile.Reader(**files, encoding="utf-8")


def write(name, data):
    (output / f"{name}.json").write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":")) + "\n")


def write_boundaries(name, data):
    compressor = zlib.compressobj(level=9, wbits=-15)
    with (output / f"{name}.deflate").open("wb") as stream:
        stream.write(compressor.compress(b"["))
        for index, polygon in enumerate(data):
            stream.write(compressor.compress(("," if index else "").encode()))
            stream.write(compressor.compress(json.dumps(polygon, separators=(",", ":")).encode()))
        stream.write(compressor.compress(b"]") + compressor.flush())


def polygons(reader):
    for item in reader.iterShapeRecords():
        code = item.record[0]
        if not code or not item.shape.points:
            continue
        geometry = shape(item.shape.__geo_interface__).simplify(0.00012, preserve_topology=True)
        for polygon in geometry.geoms if geometry.geom_type == "MultiPolygon" else (geometry,):
            if polygon.is_empty:
                continue
            rings = [[round(v * 100000) for point in ring.coords for v in point]
                     for ring in (polygon.exterior, *polygon.interiors)]
            yield [code, [round(v * 100000) for v in polygon.bounds], rings]


quake = reader("quake")
quake_names = {text(r[1]) for r in quake.records() if r[0]}
pref_by_name = {}
pref = None
for row in re.findall(r"<tr\b[^>]*>(.*?)</tr>", (source / "shindo.html").read_text(), re.S | re.I):
    cells = [text(html.unescape(re.sub(r"<[^>]+>", "", c)))
             for c in re.findall(r"<td\b[^>]*>(.*?)</td>", row, re.S | re.I)]
    if len(cells) >= 2 and cells[-2] in quake_names:
        if len(cells) >= 3:
            pref = cells[-3]
        pref_by_name[cells[-2]] = pref
assert quake_names == pref_by_name.keys(), quake_names - pref_by_name.keys()
quake_areas = [{"id": r[0], "pref": pref_by_name[text(r[1])], "name": r[1]}
               for r in quake.records() if r[0]]

tsunami = {text(r[1]): {"id": r[0], "name": r[1]} for r in reader("tsunami", False).records() if r[0]}
city = reader("city")
city_names = defaultdict(set)
prefecture_pattern = re.compile(r"^(北海道|東京都|大阪府|京都府|.{2,3}県)")
for code, full, short, _ in city.records():
    if not code or not (match := prefecture_pattern.match(full)):
        continue
    pref = match.group()
    local = full[len(pref):]
    parent, _, district = local.partition("のうち")
    for label in [short, local, parent, district, re.sub(r"^.+?郡", "", parent)]:
        if label:
            city_names[pref, text(label)].add(code)

city_areas = defaultdict(set)
unmatched = set()
aliases = {
    "洲本市東部沿岸・南部沿岸": "洲本市", "洲本市西部沿岸": "洲本市",
    "八雲町八雲": "八雲町", "八雲町熊石": "八雲町", "北見市常呂": "北見市",
    "大阪堺市": "堺市",
}
# The municipality GIS has unnumbered island polygons here, but no municipality boundaries.
no_municipal_geometry = {"色丹村", "国後泊村", "留別村", "留夜別村", "紗那村", "蘂取村"}
city_names["長崎県", "佐世保市"] = {"4220201", "4220202"}
city_names["鹿児島県", "薩摩川内市"] = {"4621501", "4621502"}
with pdfplumber.open(source / "tsunami.pdf") as pdf:
    for page in pdf.pages:
        area = None
        for label, prefecture, entries in page.extract_table()[1:]:
            if label:
                area = text(label)
            pref = text(prefecture).split("(")[0]
            if area not in tsunami:
                raise ValueError(f"Unknown tsunami area {area}")
            for entry in text(entries).split("、"):
                municipality = entry.split("(")[0]
                if pref == "北海道" and municipality in no_municipal_geometry:
                    continue
                codes = city_names.get((pref, aliases.get(municipality, municipality)))
                if not codes:
                    unmatched.add((pref, municipality))
                else:
                    for code in codes:
                        city_areas[code].add(tsunami[area]["id"])

if unmatched:
    raise ValueError(f"Unmatched municipality names: {sorted(unmatched)}")

write("notification-regions-national", {
    "earthquakeAreas": quake_areas, "tsunamiAreas": sorted(tsunami.values(), key=lambda item: item["id"]),
    "municipalTsunamiAreas": {code: sorted(ids) for code, ids in sorted(city_areas.items())},
})
write_boundaries("notification-region-earthquake-boundaries", polygons(quake))
write_boundaries("notification-region-municipality-boundaries", polygons(city))
