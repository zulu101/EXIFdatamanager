# EXIF Data Manager

Eine schlichte macOS-App, um **eingescannte analoge Fotos** mit Metadaten zu versehen –
damit Aufnahmedatum, Ort und die abgebildeten Personen auch in Jahrzehnten noch bekannt sind.

Die Angaben werden **direkt in die Bilddateien** geschrieben, in etablierten Standards
(EXIF, IPTC und XMP). So können sie auch Apple Fotos, Lightroom, digiKam oder künftige
Programme lesen – unabhängig von dieser App.

## Funktionen

- **Aufnahmedatum mit Genauigkeit:** „nur Jahr“, „Monat & Jahr“, „genauer Tag“ oder „Tag & Uhrzeit“.
- **Aufnahmeort:** Ortssuche, Klick in die Karte, automatische Ermittlung von Stadt/Region/Land,
  eigene Ortsbezeichnung (z. B. „Haus der Großeltern“) und eine Liste zuletzt verwendeter Orte.
- **Personen:** Namen werden gemerkt und beim nächsten Foto vorgeschlagen.
- **Gesichter markieren:** Rahmen mit der Maus aufziehen und benennen, oder Gesichter automatisch
  erkennen lassen (lokal auf dem Mac, mit Apples Vision-Framework). Experimentell: Namensvorschläge
  anhand bereits benannter Gesichter.
- **Beschreibung und Schlagwörter.**
- **Stapelbearbeitung:** Mehrere Fotos auswählen (⇧/⌘-Klick) und Datum, Ort, Personen usw.
  auf einmal setzen – ideal für einen ganzen Film.
- **„Vom vorherigen Foto übernehmen“** für Bildserien.
- **Sicher speichern:**
  - Die Bilddaten werden nicht neu komprimiert, nur die Metadaten werden ersetzt.
  - Die neue Datei wird erst geprüft und ersetzt dann das Original.
  - Optional wird vor dem ersten Speichern eine Sicherungskopie angelegt (Standard: an).
  - Nach dem Speichern liest die App die Datei erneut ein und meldet Abweichungen.
- Unterstützte Formate: JPEG, TIFF, PNG (HEIC je nach macOS-Version).

## Wo landen die Daten in der Datei?

| Angabe | Gespeichert in |
| --- | --- |
| Aufnahmedatum | EXIF `DateTimeOriginal` (immer vollständig, fehlende Teile = 1. Jan. bzw. 00:00 Uhr) und XMP `photoshop:DateCreated` (mit echter Genauigkeit, z. B. `1985` oder `1985-07`) |
| Koordinaten | EXIF GPS (`GPSLatitude`/`GPSLongitude` + Ref) |
| Ortsbezeichnung | XMP `Iptc4xmpCore:Location` (IPTC Sublocation) |
| Stadt / Region / Land | XMP `photoshop:City` / `photoshop:State` / `photoshop:Country` |
| Personen | XMP `Iptc4xmpExt:PersonInImage` **und** als Schlagwort in `dc:subject` |
| Gesichtsrahmen | XMP `mwg-rs:Regions` (Metadata Working Group, Typ „Face“) **und** `Iptc4xmpExt:ImageRegion` (IPTC, Inhaltstyp „human“, mit „Person im Bild“) |
| Schlagwörter | XMP `dc:subject` |
| Beschreibung | EXIF `ImageDescription` / XMP `dc:description` |

Personen werden zusätzlich als Schlagwort gespeichert, weil viele Programme (u. a. Apple Fotos)
das IPTC-Feld „Person im Bild“ nicht anzeigen, Schlagwörter aber schon.

### Gesichter

Rahmen und Namen werden in **zwei offenen Standards** gespeichert, damit möglichst viele Programme
sie lesen können: MWG-Regionen (z. B. Lightroom Classic, digiKam, ExifTool) und IPTC-Bildregionen
(offizieller IPTC-Standard seit 2019). Die Koordinaten beziehen sich – wie vom MWG-Standard
verlangt – auf das gespeicherte, ungedrehte Bild; gedrehte Fotos werden korrekt umgerechnet.
Regionen anderer Art aus anderen Programmen (z. B. Haustiere) bleiben erhalten.

Die automatische Erkennung findet nur, *wo* Gesichter sind. Für Namensvorschläge vergleicht die App
Bildausschnitte mit bereits benannten Gesichtern der geladenen Fotos. Diese Vergleichsdaten werden
nur im Arbeitsspeicher berechnet und **nie** gespeichert – in der Datei landen ausschließlich
Rahmen und Namen. Apple Fotos zeigt die Rahmen nicht an, übernimmt aber die Namen als Schlagwörter.

Der vom Scanner gesetzte Zeitpunkt der Digitalisierung (`DateTimeDigitized`) und andere vorhandene
Angaben bleiben unverändert.

## Installation

### Variante A: Fertige App aus GitHub Actions

1. Im Repository unter **Actions → Build & Test** den letzten erfolgreichen Lauf öffnen.
2. Das Artefakt **EXIF-Data-Manager** herunterladen und entpacken.
3. Die App ist nicht notarisiert. Beim ersten Start daher **Rechtsklick → Öffnen** wählen,
   oder unter *Systemeinstellungen → Datenschutz & Sicherheit* „Dennoch öffnen“ klicken.

### Variante B: Selbst bauen

Voraussetzung: macOS 14 (Sonoma) oder neuer und Xcode (oder die Command Line Tools).

```bash
git clone https://github.com/zulu101/EXIFdatamanager.git
```

```bash
cd EXIFdatamanager && ./scripts/build-app.sh
```

Die App liegt danach unter `build/EXIF Data Manager.app` und kann in den Programme-Ordner
gezogen werden.

Zum Entwickeln lässt sich das Projekt direkt in Xcode öffnen (`open Package.swift`) oder mit
`swift run` starten. Tests: `swift test`.

## Bedienung

1. Fotos oder ganze Ordner ins Fenster ziehen (oder ⌘O).
2. Foto in der Liste auswählen und rechts Datum, Ort, Personen und Beschreibung eintragen.
3. Mit ⌘↑ / ⌘↓ zum vorherigen/nächsten Foto wechseln.
4. **⌘S** schreibt alle Änderungen in die Dateien. Ein orangefarbener Punkt in der Liste zeigt
   ungespeicherte Änderungen, ein grüner Haken: Datum und Ort sind eingetragen.

## Tipps zur Langzeit-Archivierung

- Die Beschreibung ist das wertvollste Feld: Anlass, wer wo steht, kleine Geschichten.
- Wenn das Datum unsicher ist, lieber „nur Jahr“ wählen und z. B. „ca. 1975“ in die Beschreibung
  schreiben.
- Weiterhin regelmäßig Backups machen (z. B. Time Machine und eine Kopie außer Haus).

## Projektaufbau

```
Sources/ExifCore/          Metadaten lesen/schreiben (ImageIO), ohne Oberfläche, getestet
Sources/ExifDataManager/   SwiftUI-App
Tests/ExifCoreTests/       Tests inkl. Schreib-/Lese-Durchlauf mit echten JPEG/TIFF/PNG
scripts/build-app.sh       Baut das .app-Bundle (inkl. Icon)
Resources/AppIcon.svg      App-Icon (Quelle), AppIcon.png = gerenderte 1024-px-Version
```
