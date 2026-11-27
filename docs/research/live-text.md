# Live Text: select text in images and the camera

Board task `select-text-in-images-and-the-camera` (stock-parity-gaps.md row "Live Text / Visual Look Up", #22).
Before this, PowOS only took screenshots for the assistant; no text in a picture could be selected.

## v1 (2026-11-27)

`targets/android/app/app/src/main/kotlin/dev/omalauncher/livetext/`

| Entry point | How |
|---|---|
| Any image, any app (incl. Android's screenshot share button) | share sheet target **"Copy text"** (`LiveTextActivity`, `ACTION_SEND image/*`) |
| Camera | **"Scan text"**: Quick Settings tile `ScanTextTile`, or intent `dev.omalauncher.action.SCAN_TEXT`; the camera app takes a still (`ACTION_IMAGE_CAPTURE` into our FileProvider `cache/share/livetext/`), then it is read |

The image fills the window, every word read gets a soft box. Drag across words selects a run (across lines), a tap
selects the word's line, **All** selects everything. The bar copies, shares, searches (`ACTION_WEB_SEARCH`, else
DuckDuckGo) or translates (`ACTION_TRANSLATE`, else the `PROCESS_TEXT` handlers, else the web). Phone numbers
(dial), links, emails and street addresses (`geo:` search) become chips (`Entities`, regex, tested).

No root, no new permission: the camera app holds the camera; the shared image arrives with a read grant.

Not in v1: a live viewfinder lens (needs CameraX or camera2 preview; the still-photo path covers "point and read"),
PowOS's own screenshot editor (there is none; Android's screenshot share reaches "Copy text"), the lock-screen camera
shortcut (d40cdeb2 opens the camera app's secure mode, not a PowOS view, so it can't carry Live Text), a button in the
PowOS shell itself (the shade/launcher could fire `SCAN_TEXT`), word-level boxes from PowStation (its spotting gives
line boxes; words are split by character share).

## OCR decision

Two readers, the device first, PowStation second:

1. **On device: ML Kit text recognition, bundled Latin model** (`com.google.mlkit:text-recognition:16.0.1`).
   - The bundled artifact carries the model in the APK; it runs offline with no Google Play Services (the
     `play-services-mlkit-text-recognition` variant is the one that needs GMS; we don't use it). Works non-root.
   - Size: the bundled-common AAR is 16.7 MB for all ABIs; the app is arm64-only (`abiFilters`), Google documents
     ~4 MB per architecture for the Latin model. Latin script only (Chinese/Japanese/Korean/Devanagari are separate
     ~10 MB models; not added).
   - Licence: free to use under the ML Kit / Google APIs Terms of Service; closed source. ML Kit may send usage
     metrics through Google's transport when GMS is present; images never leave the device.
   - Word boxes, ~100-300 ms per image on a phone (not yet measured on ours: the phone check reports it).
   - Rejected: Tesseract (tesseract4android, Apache-2.0): similar size (native lib + `eng.traineddata` fast ~4 MB)
     but clearly worse on camera photos (needs binarised, deskewed input) and slower. Kept as the fallback if the
     ML Kit terms ever become a problem; the `Read`/`Word` model is engine-neutral.
2. **PowStation: PowScan's `/api/ocr` `spot` mode** (`http://powscan.pow/api/ocr`, PaddleOCR-VL-1.6 0.9B, Apache-2.0,
   model `ocr` on gpu-195's llm-pool). Reused as-is: no new pool entry, no model loaded by us; the pool swaps it in.
   Better on handwriting, other scripts and dense pages. LAN/VPN only. Its read replaces the device's when it holds
   more non-space characters. Measured on the fixture from the Mac: cold (model swapped in) 52.8 s, warm 0.45 s, all
   5 lines exact with line quads - hence a 60 s read timeout in the background, the device read already shown.

Smallest that meets "offline + good": ML Kit bundled Latin. PowStation adds quality at zero APK cost.

## Checks

- Gate: `LiveTextTest` (JVM): PowStation's real read of `src/test/resources/livetext/fixture.png`
  (`fixture.powstation.json`) parses in reading order, drag/tap selections, entity detection on the fixture
  (+47 phone, www link, email, "Storgata 12, 0155 Oslo") and other shapes (dates/prices are not phones).
- Phone: `tools/phone/verify/live-text.sh` pushes the fixture, shares it to "Copy text" with the report extra and judges
  the device read (lines + PHONE/URL/EMAIL/ADDRESS); PowStation's read is reported, not judged.

## Next

- Live lens: a camera2 preview with ML Kit on frames (boxes over the viewfinder), reached from the shell's camera
  shortcut once PowOS has its own camera view.
- Shell entry: "Scan text" in the launcher search / quick tools.
- More scripts (ML Kit CJK/Devanagari bundles) on demand.
