# PickShot Image Loading Speed Research

Research date: April 2026

## Current Architecture

PickShot uses `CGImageSourceCreateThumbnailAtIndex` for thumbnails and previews, with a 2-stage loading pipeline for RAW files (1200px fast preview, then full-res). The `PreviewImageCache` is a hybrid RAM+disk LRU cache. This is already one of the fastest approaches available on macOS.

---

## 1. libjpeg-turbo

**What it does:** A JPEG codec using SIMD instructions (SSE2, AVX2, NEON) for 2-6x faster JPEG compression/decompression vs standard libjpeg.

**How fast vs current:** For JPEG decoding specifically, libjpeg-turbo can be 2-6x faster than the standard libjpeg library. However, Apple's ImageIO framework (CGImageSource) on Apple Silicon already uses hardware-accelerated JPEG decoding. On M-series chips, CGImageSource achieves ~16ms for JPEG thumbnails, which is competitive with libjpeg-turbo's optimized path. The gains would be marginal on Apple Silicon but potentially meaningful on older Intel Macs.

**Integration into PickShot:** A Swift wrapper exists (SwiftLibjpegTurbo via SPM). Would require bridging C code and managing a separate decode path for JPEG files only.

**Difficulty:** Medium. SPM integration is straightforward, but maintaining two decode paths (libjpeg-turbo for JPEG, CGImageSource for everything else) adds complexity. The benefit on Apple Silicon is minimal since Apple's hardware JPEG decoder is already fast.

**Verdict:** Not recommended for PickShot. The current CGImageSource path is already near-optimal on Apple Silicon. The complexity cost outweighs the marginal gains.

**Sources:**
- https://libjpeg-turbo.org/
- https://github.com/libjpeg-turbo/libjpeg-turbo/releases
- https://github.com/ayushi2103/SwiftLibjpegTurbo

---

## 2. LibRaw for RAW Thumbnail Extraction

**What it does:** C/C++ library for reading RAW files from 1000+ camera models. Can extract embedded JPEG thumbnails using `open_file()` + `unpack_thumb()` without decoding the full RAW data.

**How fast vs current:** LibRaw's `unpack_thumb()` extracts the embedded JPEG preview in ~5-15ms for most camera files, since it only reads the JPEG offset from the file header without touching the Bayer data. PickShot's current approach using CGImageSource with `kCGImageSourceCreateThumbnailFromImageIfAbsent: false` does something similar (extracts embedded preview), so performance should be comparable. LibRaw's advantage is broader format support, especially for newer camera models that Apple's ImageIO may not support yet (e.g., some Nikon Z8/Z9 High Efficiency RAW variants).

**Integration into PickShot:** Would require a C bridging header and linking against libraw. The library is available via Homebrew (`brew install libraw`) or can be compiled from source and bundled.

**Difficulty:** Medium-High. Requires C/C++ bridging, memory management across the Swift/C boundary, and bundling the library. PickShot already has a fallback binary JPEG scanner for unsupported RAW formats (scanning for FFD8 markers), which covers many edge cases LibRaw would handle.

**Verdict:** Worth considering only if PickShot needs to support RAW formats that CGImageSource cannot decode. The current embedded-JPEG extraction + binary scanner fallback covers most cases.

**Sources:**
- https://github.com/LibRaw/LibRaw
- https://www.libraw.org/about
- https://www.libraw.org/node/2177

---

## 3. Carpaccio (Swift RAW Library)

**What it does:** A native Swift library for macOS/iOS that decodes image data and EXIF metadata from formats supported by CoreImage, including RAW files. Uses CoreImage's RAW decoding capability under the hood. Supports parallel multi-core decoding for metadata, thumbnails, and image data.

**How fast vs current:** Carpaccio uses the same underlying CoreImage/CGImageSource APIs that PickShot already uses. It adds a Swift-friendly wrapper with parallel processing, but the raw decode speed would be identical since both use Apple's decoders. The parallel metadata extraction could be useful for batch operations but does not speed up individual image loading.

**Integration into PickShot:** Available via SPM. However, since PickShot already calls the same underlying APIs directly, wrapping them in Carpaccio would add a dependency without meaningful performance gains.

**Difficulty:** Low (SPM package). But no performance benefit.

**Verdict:** Not recommended. PickShot already uses the same underlying APIs. Adding Carpaccio would be an abstraction layer with no speed improvement.

**Sources:**
- https://github.com/mz2/Carpaccio

---

## 4. CGImageSource (Current Approach) -- Benchmark Data

PickShot's current approach is already one of the fastest. Published benchmarks show:

| Format | NSImage (ms) | CGImageSource (ms) | Speedup |
|--------|-------------|--------------------| --------|
| JPEG   | 628         | 16                 | 40x     |
| PNG    | 675         | 145                | 4.6x    |
| HEIC   | 637         | 43                 | 15x     |

Key optimizations already in use by PickShot:
- `kCGImageSourceShouldCache: false` -- prevents double-caching in system memory
- `kCGImageSourceShouldCacheImmediately: true` -- decodes on creation, not on first draw
- `kCGImageSourceThumbnailMaxPixelSize` -- hardware-accelerated downscaling
- `kCGImageSourceCreateThumbnailFromImageIfAbsent: false` first (extract embedded), then `true` as fallback (generate)

**Sources:**
- https://macguru.dev/fast-thumbnails-with-cgimagesource/
- https://developer.apple.com/documentation/imageio/cgimagesource

---

## 5. Nuke Framework

**What it does:** A comprehensive Swift image loading and caching framework. Handles downloading, caching, processing, and displaying images. Supports macOS and iOS. Claims to be 3.5x faster than competing frameworks (Kingfisher, SDWebImage) due to reduced allocations and dynamic dispatch.

**How fast vs current:** Nuke is optimized for network image loading with disk+memory caching. For local file loading (PickShot's use case), Nuke would likely use CGImageSource internally, so decode speed would be the same. The caching layer is well-engineered but PickShot's custom PreviewImageCache (hybrid RAM+disk LRU with memory pressure awareness) is already tailored to the photo browser use case.

**Integration into PickShot:** Available via SPM. Would replace PreviewImageCache and the loading pipeline.

**Difficulty:** Medium. Would require reworking the preview loading architecture. But since PickShot's cache is already custom-tuned for RAW+JPG workflows, Nuke would not add value.

**Verdict:** Not recommended for PickShot. Nuke excels at network image loading. For local file browsing with mixed RAW/JPG, the current custom cache is better suited.

**Sources:**
- https://github.com/kean/Nuke
- https://kean.blog/nuke/home

---

## 6. GPUImage3 / Metal-Based Processing

**What it does:** BSD-licensed Swift framework for GPU-accelerated video and image processing using Metal. Can apply filters, resize, and process images entirely on the GPU.

**How fast vs current:** Metal-based processing excels for real-time filters and effects but is not faster than CGImageSource for simple decode+resize operations. The bottleneck for image loading is I/O and JPEG decode, not pixel processing. Metal shaders add overhead for simple operations (texture upload, command buffer submission).

**Integration into PickShot:** Available via SPM. Would only be useful if PickShot added GPU-based color correction or filter preview functionality.

**Difficulty:** Medium. Metal programming complexity.

**Verdict:** Not recommended for loading speed. Potentially useful for future real-time filter/correction preview features.

**Sources:**
- https://github.com/BradLarson/GPUImage3

---

## 7. macOS-Specific Optimizations (Actionable for PickShot)

These are optimizations that can be applied within the current architecture:

### 7a. Memory-Mapped I/O (`Data(contentsOf:options:.mappedIfSafe)`)
Already used by PickShot's binary JPEG scanner fallback. Could be extended to all file reads to avoid copying file data into process memory.

### 7b. Prefetch Window Size
**Previously:** PickShot prefetched 5 images in each direction.
**Now (this update):** Extended to 20 in each direction with smart resolution selection (1200px for RAW, original for JPG). This is the single biggest practical improvement for perceived speed.

### 7c. Thumbnail Subsample Factor for JPEG
CGImageSource can use `kCGImageSourceSubsampleFactor` (values: 2, 4, 8) for JPEG files to decode at 1/2, 1/4, or 1/8 resolution during the decode step itself, skipping inverse DCT for unused blocks. This is faster than decoding full resolution and then resizing. PickShot could use this for the thumbnail grid.

### 7d. Dispatch QoS Tuning
Using `.utility` QoS for prefetch (instead of `.userInitiated`) prevents prefetch work from competing with the currently-viewed photo's decode. This is now implemented in the smart preload system.

### 7e. DispatchWorkItem Cancellation
Cancelling stale prefetch batches when the user navigates rapidly prevents wasted CPU cycles on images the user has already scrolled past. Now implemented.

---

## Summary: Recommended Actions

| Priority | Action | Expected Impact | Status |
|----------|--------|-----------------|--------|
| 1 | Expand prefetch window to +-20 | Major perceived speed improvement | DONE |
| 2 | Cancel stale prefetch on rapid navigation | Reduces CPU waste | DONE |
| 3 | Smart resolution for prefetch (1200px RAW, orig JPG) | Faster RAW prefetch | DONE |
| 4 | Consider kCGImageSourceSubsampleFactor for grid thumbnails | 2-4x faster JPEG thumbnails | TODO |
| 5 | Memory-mapped I/O for all file reads | Minor memory improvement | TODO |
| - | libjpeg-turbo | Marginal on Apple Silicon | NOT RECOMMENDED |
| - | LibRaw | Only if format support gaps found | CONDITIONAL |
| - | Carpaccio | No speed benefit over current | NOT RECOMMENDED |
| - | Nuke | Wrong tool for local files | NOT RECOMMENDED |
| - | GPUImage3/Metal | Wrong tool for decode speed | NOT RECOMMENDED |

**Bottom line:** PickShot's current CGImageSource-based architecture is already near-optimal for macOS image loading. The biggest practical gains come from smarter prefetching (wider window, cancellation, resolution-aware loading), not from swapping out the decode library.
