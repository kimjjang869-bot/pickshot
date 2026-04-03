# PickShot Feature Roadmap - Competitive Analysis & Planning

**Last updated:** 2026-04-03
**Scope:** Feature gap analysis against 6 major competitors, prioritized roadmap

---

## 1. PickShot Current Feature Inventory

| Category | Feature | Status |
|----------|---------|--------|
| **Viewing** | RAW + JPG pair viewing | Done |
| | Thumbnail grid + filmstrip layouts | Done |
| | Full-screen preview | Done |
| | Photo comparison (up to 4 photos) | Done |
| | Slideshow | Done |
| | Histogram (RGB + luminance) | Done |
| | EXIF info overlay | Done |
| **Culling** | Star rating (0-5) | Done |
| | Color labels (7 colors) | Done |
| | Space pick (quick select) | Done |
| | Keyboard-driven workflow | Done |
| | Sorting (date, name, rating, space pick) | Done |
| | Quality filters (all, space pick, AI pick, good, issues, best-of-duplicates) | Done |
| **AI / Analysis** | Blur detection | Done |
| | Closed eyes detection | Done |
| | Face focus check | Done |
| | Exposure analysis | Done |
| | Duplicate grouping (best-of-group) | Done |
| | AI vision analysis (Claude API) | Done |
| | Scene classification (portrait, landscape, food, etc.) | Done |
| | Face grouping (unlabeled) | Done |
| | Quality grading (excellent to poor) | Done |
| **Image Correction** | Auto horizon straighten | Done |
| | Auto exposure adjustment | Done |
| | Auto white balance | Done |
| **Export** | Export to folder (rated/selected/filtered/all) | Done |
| | Lightroom export (RAW + XMP sidecar with ratings) | Done |
| | Google Drive upload (local + API) | Done |
| | Batch rename | Done |
| **Tethering** | Camera detection via USB (ImageCaptureCore) | Done |
| | Auto-download captured photos | Done |
| | Output folder selection | Done |
| **Map** | GPS photo map (MapKit) | Done |
| | Photo annotations on map | Done |
| **Client** | PickShot Client companion app | Done |
| | G-Select (instant Google Drive upload) | Done |
| **Other** | Folder browser / navigation | Done |
| | Folder watching (live reload) | Done |
| | Dark mode | Done |
| | Touch Bar support | Done |
| | Hardware-accelerated image engine | Done |
| | Undo/Redo (ratings, picks) | Done |
| | .pickshot file format | Done |

---

## 2. Feature Comparison Table (PickShot vs Competitors)

Legend: Y = Yes, P = Partial, N = No

| Feature | PickShot | Photo Mechanic Plus | Capture One | Lightroom Classic | AfterShoot | FilterPixel | FastRawViewer |
|---------|----------|-------------------|-------------|-------------------|------------|-------------|---------------|
| **FILE CONVERSION** | | | | | | | |
| RAW to DNG conversion | N | Y (via Adobe DNG Converter) | Y | Y (on import) | N | N | N |
| RAW to JPG export | N | Y | Y | Y | N | N | N |
| Batch resize on export | N | Y | Y | Y | N | N | N |
| **BATCH OPERATIONS** | | | | | | | |
| Batch rename | Y | Y | Y | Y | N | N | N |
| Batch metadata write | N | Y | Y | Y | N | N | N |
| Batch file move/copy | P (export only) | Y | Y | Y | N | N | Y |
| Batch auto-correct | N | N | Y | Y | N | N | N |
| **METADATA** | | | | | | | |
| EXIF read | Y | Y | Y | Y | Y | Y | Y |
| IPTC/XMP write | P (XMP sidecar for LR) | Y (full) | Y (full) | Y (full) | N | N | Y (XMP) |
| Keyword tagging | N | Y | Y | Y | N | N | N |
| Caption/title editing | N | Y | Y | Y | N | N | N |
| Copyright/credit fields | N | Y | Y | Y | N | N | N |
| Stationery pad / templates | N | Y | N | Y (presets) | N | N | N |
| **PRINT / CONTACT SHEET** | | | | | | | |
| Contact sheet generation | N | Y | Y | Y | N | N | N |
| Print module | N | Y | Y | Y | N | N | N |
| PDF contact sheet export | N | Y | Y | Y | N | N | N |
| **WATERMARK** | | | | | | | |
| Text watermark on export | N | Y | Y | Y | N | N | N |
| Image/logo watermark | N | Y | Y | Y | N | N | N |
| **FTP / UPLOAD** | | | | | | | |
| FTP/SFTP upload | N | Y | N | N (via publish) | N | N | N |
| Google Drive upload | Y | N | N | N | N | N | N |
| Cloud service integration | Y (Google Drive) | Y (PhotoShelter, etc.) | N | Y (Adobe Cloud) | N | Y (cloud cull) | N |
| **SMART COLLECTIONS** | | | | | | | |
| Saved smart filters | N | Y (catalogs) | Y (smart albums) | Y | N | N | N |
| Rule-based auto-grouping | P (scene/face groups) | Y | Y | Y | N | N | N |
| Persistent catalog | N | Y | Y | Y | N | N | N |
| **FACE RECOGNITION** | | | | | | | |
| Face detection | Y | N | Y | Y | Y | Y | N |
| Face grouping | Y | N | Y | Y | N | N | N |
| Face naming (assign names) | N | N | Y | Y | N | N | N |
| People search by name | N | N | Y | Y | N | N | N |
| **GPS / MAP** | | | | | | | |
| Map view of GPS photos | Y | Y | Y | Y | N | N | N |
| Reverse geocoding (place names) | N | Y | Y | Y | N | N | N |
| Manual GPS assignment | N | Y | N | Y | N | N | N |
| GPS track log import | N | Y | N | Y | N | N | N |
| **COLOR GRADING / PRESETS** | | | | | | | |
| Color grading tools | N | N | Y (advanced) | Y (advanced) | N | N | N |
| Preset/style system | N | N | Y (styles) | Y (presets) | Y (AI editing) | Y (AI editing) | N |
| Curves/levels | N | N | Y | Y | N | N | Y (basic) |
| **TETHERED SHOOTING** | | | | | | | |
| USB tether capture | Y | N | Y (best-in-class) | Y | N | N | N |
| Wireless tethering | N | N | Y | N | N | N | N |
| Live view | N | N | Y | Y | N | N | N |
| Camera settings control | N | N | Y | N | N | N | N |
| **MULTI-MONITOR** | | | | | | | |
| Detachable panels | N | N | Y | Y | N | N | N |
| Second display preview | N | N | Y | Y | N | N | N |
| **WORKSPACE** | | | | | | | |
| Custom workspace layouts | N | N | Y | N | N | N | N |
| Saveable workspaces | N | N | Y | N | N | N | N |
| **AI CULLING** | | | | | | | |
| AI auto-cull | Y (AI pick) | N | N | P (subject focus) | Y (core feature) | Y (core feature) | N |
| AI learns user style | N | N | N | N | Y | Y | N |
| Genre-based AI cull | N | N | N | N | N | Y (DeepCull) | N |
| Target keeper count | N | N | N | N | Y (planned) | N | N |
| **RAW PROCESSING** | | | | | | | |
| RAW histogram | N | N | Y | Y | N | N | Y (actual RAW data) |
| Shadow boost inspection | N | N | N | N | N | N | Y |
| Focus peaking | N | N | Y | N | N | N | Y |
| Overexposure/underexposure warnings | N | N | Y | Y | N | N | Y |
| Per-channel view | N | N | Y | N | N | N | Y |

---

## 3. Missing Features Prioritized by User Value

### Priority 1 - HIGH VALUE (Strong user demand, competitive necessity)

| # | Feature | Why It Matters | Competitors With It |
|---|---------|---------------|-------------------|
| 1 | **RAW to JPG batch export with resize** | Photographers need to deliver web-ready JPGs without opening another app | PM+, C1, LR |
| 2 | **Watermark on export** (text + image) | Essential for client proofing and social media delivery | PM+, C1, LR |
| 3 | **Face naming / people tagging** | PickShot already detects and groups faces -- adding names is the natural next step | C1, LR |
| 4 | **IPTC/XMP metadata editing** (keywords, caption, copyright) | Professional photographers must embed metadata before delivery | PM+, C1, LR, FRV |
| 5 | **Contact sheet / proof sheet** (print + PDF) | Wedding and event photographers need this for client review | PM+, C1, LR |
| 6 | **Smart collections / saved filters** | Users want to save and recall complex filter combinations | PM+, C1, LR |
| 7 | **Focus peaking overlay** | Critical for culling -- quickly see what is in focus | C1, FRV |
| 8 | **Overexposure / underexposure warnings** (zebra stripes) | Fast visual check for blown highlights or crushed shadows | C1, LR, FRV |

### Priority 2 - MEDIUM VALUE (Differentiating, power-user features)

| # | Feature | Why It Matters | Competitors With It |
|---|---------|---------------|-------------------|
| 9 | **RAW to DNG conversion** | DNG is the archival standard; many photographers convert on import | PM+, C1, LR |
| 10 | **Multi-monitor / second display** | Studio photographers want full-screen preview on a second monitor | C1, LR |
| 11 | **FTP/SFTP upload** | Press and sports photographers need instant delivery to wire services | PM+ |
| 12 | **AI learns user culling style** | Personalized AI that improves over time is a major differentiator | AfterShoot, FilterPixel |
| 13 | **Reverse geocoding** (GPS coords to place names) | Map view is more useful with actual location names | PM+, C1, LR |
| 14 | **Tethered live view** | See what the camera sees before shooting | C1, LR |
| 15 | **Batch metadata templates** (stationery pad) | Apply photographer name, copyright, contact info to all photos at once | PM+, LR |
| 16 | **Genre-based AI culling** (wedding, sports, event modes) | Different genres need different quality criteria | FilterPixel |

### Priority 3 - LOWER VALUE (Nice-to-have, niche audience)

| # | Feature | Why It Matters | Competitors With It |
|---|---------|---------------|-------------------|
| 17 | **Color grading presets/styles** | Quick looks for proofing, not PickShot's core strength | C1, LR |
| 18 | **Custom workspace layouts** | Power users want to arrange panels their way | C1 |
| 19 | **Wireless tethering** | Convenience for fashion/studio shoots | C1 |
| 20 | **Camera settings remote control** | Control ISO, shutter, aperture from the app | C1 |
| 21 | **GPS track log import** | Match photos to GPX tracks from a phone or GPS device | PM+, LR |
| 22 | **Per-channel histogram** (RAW-based) | Technical users want to see actual RAW channel data | FRV |
| 23 | **Shadow boost / highlight inspection tool** | Deep shadow visibility without permanent edits | FRV |
| 24 | **Persistent catalog database** | Long-term photo organization across sessions | PM+, C1, LR |
| 25 | **Target keeper count AI** ("keep best 50 from 500") | Unique AfterShoot feature, very workflow-friendly | AfterShoot (planned) |

---

## 4. Implementation Difficulty Estimates

| Feature | Difficulty | Estimated Dev Time | Dependencies |
|---------|-----------|-------------------|--------------|
| RAW to JPG batch export + resize | Medium | 2-3 weeks | CoreImage, ImageIO |
| Text watermark on export | Easy | 1 week | CoreGraphics overlay |
| Image/logo watermark on export | Easy | 1 week | CoreGraphics composite |
| Face naming (add names to face groups) | Medium | 2 weeks | Extend FaceGroupingService, add name persistence |
| IPTC/XMP metadata editing | Medium-Hard | 3-4 weeks | CGImageMetadata API, XMP sidecar write |
| Contact sheet (print + PDF) | Medium | 2-3 weeks | NSPrintOperation, PDFKit |
| Smart collections / saved filters | Medium | 2-3 weeks | Codable filter rules, UserDefaults/JSON persistence |
| Focus peaking overlay | Medium | 2 weeks | CoreImage edge detection + overlay compositing |
| OE/UE zebra warnings | Easy-Medium | 1-2 weeks | CoreImage threshold filter, overlay |
| RAW to DNG conversion | Medium | 2 weeks | Shell out to Adobe DNG Converter or use LibRaw |
| Multi-monitor / second display | Medium-Hard | 3 weeks | NSWindow on secondary screen, sync state |
| FTP/SFTP upload | Medium | 2-3 weeks | NMSSH/libssh2 or Network.framework |
| AI learns user style | Hard | 6-8 weeks | ML model training, CoreML on-device, feedback loop |
| Reverse geocoding | Easy | 1 week | CLGeocoder API |
| Tethered live view | Hard | 4-6 weeks | ImageCaptureCore live view, real-time stream |
| Batch metadata templates | Medium | 2 weeks | Template editor UI, apply-to-all logic |
| Genre-based AI culling | Hard | 4-6 weeks | Multiple ML models or prompt engineering |
| Color grading presets | Medium-Hard | 3-4 weeks | CIFilter chains, preset save/load, UI |
| Custom workspace layouts | Hard | 4-6 weeks | Draggable panels, layout serialization |
| Wireless tethering | Hard | 4-6 weeks | PTP/IP protocol, network discovery |
| Camera settings control | Hard | 4-6 weeks | PTP command set per manufacturer |
| GPS track log import | Medium | 2 weeks | GPX parser, time-based matching |
| Per-channel RAW histogram | Medium | 2 weeks | LibRaw or CoreImage RAW decode |
| Shadow boost / highlight tool | Medium | 2 weeks | CIFilter tone curve, temporary overlay |
| Persistent catalog | Hard | 8-12 weeks | SQLite/CoreData, indexing, migration |
| Target keeper count | Medium | 2-3 weeks | Score ranking + top-N selection logic |

---

## 5. Recommended Roadmap

### v3.5 - "Professional Delivery" (Target: Q3 2026)

Focus: Make PickShot a complete culling-to-delivery tool.

| Feature | Priority | Effort |
|---------|----------|--------|
| RAW to JPG batch export with resize | P1 | 2-3 weeks |
| Text + image watermark on export | P1 | 2 weeks |
| Face naming (assign names to face groups) | P1 | 2 weeks |
| Focus peaking overlay | P1 | 2 weeks |
| OE/UE zebra stripe warnings | P1 | 1-2 weeks |
| Reverse geocoding on map | P2 | 1 week |
| Smart collections / saved filter presets | P1 | 2-3 weeks |

**Total estimated effort: 12-15 weeks**

### v4.0 - "Pro Studio" (Target: Q1 2027)

Focus: Metadata mastery, multi-monitor, advanced tethering.

| Feature | Priority | Effort |
|---------|----------|--------|
| IPTC/XMP metadata editing (keywords, caption, copyright) | P1 | 3-4 weeks |
| Batch metadata templates (stationery pad) | P2 | 2 weeks |
| Contact sheet generation (print + PDF export) | P1 | 2-3 weeks |
| Multi-monitor / second display preview | P2 | 3 weeks |
| RAW to DNG conversion | P2 | 2 weeks |
| FTP/SFTP upload | P2 | 2-3 weeks |
| Tethered live view | P2 | 4-6 weeks |
| GPS track log import | P3 | 2 weeks |

**Total estimated effort: 20-25 weeks**

### v5.0 - "Intelligent Workflow" (Target: Q3 2027)

Focus: AI differentiation, personalization, catalog.

| Feature | Priority | Effort |
|---------|----------|--------|
| AI learns user culling style (on-device CoreML) | P2 | 6-8 weeks |
| Genre-based AI culling modes | P2 | 4-6 weeks |
| Target keeper count ("keep best N") | P3 | 2-3 weeks |
| Persistent catalog database | P3 | 8-12 weeks |
| Custom workspace layouts | P3 | 4-6 weeks |
| Color grading presets / quick looks | P3 | 3-4 weeks |
| Camera settings remote control (tether) | P3 | 4-6 weeks |
| Wireless tethering | P3 | 4-6 weeks |

**Total estimated effort: 36-47 weeks**

---

## 6. Strategic Notes

### PickShot's Competitive Advantages (Keep and Strengthen)

1. **Speed** - PickShot's hardware-accelerated engine and fast thumbnail loading is a key differentiator vs Lightroom and Capture One.
2. **AI-powered culling** - Blur, face focus, duplicate grouping, and Claude API analysis put PickShot ahead of Photo Mechanic and FastRawViewer.
3. **Google Drive integration** - Unique G-Select workflow for instant client delivery.
4. **macOS-native** - SwiftUI, Metal, ImageCaptureCore -- no Electron overhead.
5. **Companion client app** - PickShot Client for remote photo selection is unique in this market.

### Where PickShot Falls Shortest vs Each Competitor

| Competitor | Biggest Gap |
|-----------|-------------|
| **Photo Mechanic Plus** | Metadata editing (IPTC/XMP write), FTP upload, contact sheets, watermark |
| **Capture One** | Color grading, tethered live view + camera control, multi-monitor, custom workspaces |
| **Lightroom Classic** | Smart collections, face naming, DNG conversion, print module, persistent catalog |
| **AfterShoot** | AI that learns personal culling style, target keeper count |
| **FilterPixel** | Genre-aware AI culling (DeepCull), cloud-based speed |
| **FastRawViewer** | RAW-level histogram, focus peaking, shadow boost, OE/UE inspection |

### Quick Wins (Highest Impact, Lowest Effort)

1. Reverse geocoding (1 week, CLGeocoder is trivial)
2. Text watermark on export (1 week, CoreGraphics)
3. OE/UE zebra stripe warnings (1-2 weeks, CIFilter threshold)
4. Face naming persistence (2 weeks, extends existing face grouping)
5. Focus peaking overlay (2 weeks, edge detection filter)

---

## Sources

- [Photo Mechanic Tour](https://home.camerabits.com/tour-photo-mechanic/)
- [Photo Mechanic Contact Sheets](https://docs.camerabits.com/support/solutions/articles/48000207551-introduction-to-photo-mechanic-contact-sheets)
- [Capture One Export Recipes](https://support.captureone.com/hc/en-us/articles/360021057158-Export-Recipes)
- [Capture One Tethering](https://www.captureone.com/en/explore-features/tethering/what-is-tethered-shooting)
- [Lightroom Classic New Features](https://helpx.adobe.com/lightroom-classic/help/whats-new.html)
- [Lightroom Print Module](https://helpx.adobe.com/lightroom-classic/help/print-module-layouts-templates.html)
- [AfterShoot 2026 Roadmap](https://aftershoot.com/roadmap-2026/)
- [FilterPixel 4.0](https://filterpixel.com/blog/filterpixel-4.0)
- [FastRawViewer Features](https://www.fastrawviewer.com/features)
- [Excire Foto 2025 Review](https://amateurphotographer.com/review/excire-photo-2025-excire-search-2026-review-organising-photos-has-never-been-easier/)
