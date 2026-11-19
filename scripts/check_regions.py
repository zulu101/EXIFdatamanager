#!/usr/bin/env python3
"""Prüft, ob ExifTool die von der App geschriebenen Gesichtsregionen korrekt liest.

Erwartet wird das Beispiel aus FaceRegionTests.testWriteSampleForExifTool:
Gesicht 1 „Erika Mustermann“ bei x=0.2, y=0.3, w=0.25, h=0.2 und ein unbenanntes Gesicht.
"""
import json
import sys


def find(data, key):
    """Sucht einen Schlüssel unabhängig vom Gruppenpräfix (z. B. „XMP-mwg-rs:RegionInfo“)."""
    for k, v in data.items():
        if k == key or k.endswith(":" + key):
            return v
    raise SystemExit(f"FEHLER: {key} fehlt in der ExifTool-Ausgabe")


def close(a, b):
    return abs(float(a) - b) < 1e-4


data = json.load(open(sys.argv[1]))[0]

info = find(data, "RegionInfo")
regions = info["RegionList"]
assert len(regions) == 2, f"MWG: 2 Regionen erwartet, {len(regions)} gefunden"
first = regions[0]
assert first["Type"] == "Face", first
assert first["Name"] == "Erika Mustermann", first
area = first["Area"]
assert close(area["X"], 0.325) and close(area["Y"], 0.4), area
assert close(area["W"], 0.25) and close(area["H"], 0.2), area
assert area["Unit"] == "normalized", area
dims = info["AppliedToDimensions"]
assert int(dims["W"]) == 400 and int(dims["H"]) == 300, dims
print("✓ MWG-Regionen korrekt")

image_regions = find(data, "ImageRegion")
assert len(image_regions) == 2, f"IPTC: 2 Regionen erwartet, {len(image_regions)} gefunden"
r = image_regions[0]
b = r["RegionBoundary"]
# ExifTool zeigt die gespeicherten Werte „rectangle“/„relative“ großgeschrieben an.
assert b["RbShape"].lower() == "rectangle" and b["RbUnit"].lower() == "relative", b
assert close(b["RbX"], 0.2) and close(b["RbY"], 0.3), b
assert close(b["RbW"], 0.25) and close(b["RbH"], 0.2), b
person = r["PersonInImage"]
assert person == "Erika Mustermann" or person == ["Erika Mustermann"], person
ctype = json.dumps(r["RCtype"])
assert "http://cv.iptc.org/newscodes/imageregiontype/human" in ctype, ctype
print("✓ IPTC-Bildregionen korrekt")

people = find(data, "PersonInImage")
assert "Erika Mustermann" in (people if isinstance(people, list) else [people]), people
print("✓ Personenliste korrekt")
