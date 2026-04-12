import Foundation
import AppKit
import PDFKit

// MARK: - Contact Sheet Service

struct ContactSheetService {

    struct Options {
        var columns: Int = 4
        var rows: Int = 5
        var pageSize: NSSize = NSSize(width: 595, height: 842) // A4
        var margin: CGFloat = 30
        var spacing: CGFloat = 8
        var showFilename: Bool = true
        var showRating: Bool = true
        var showExif: Bool = false
        var headerText: String = ""     // 상단 제목
        var footerText: String = ""     // 하단 텍스트 (작가명 등)
        var backgroundColor: NSColor = .white
        var fontColor: NSColor = .black
    }

    /// 컨택트시트 PDF 생성
    static func generatePDF(
        photos: [PhotoItem],
        options: Options,
        progress: ((Int, Int) -> Void)? = nil
    ) -> Data? {
        let pdfData = NSMutableData()
        let consumer = CGDataConsumer(data: pdfData as CFMutableData)!
        var mediaBox = CGRect(origin: .zero, size: options.pageSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        let totalPhotos = photos.filter { !$0.isFolder && !$0.isParentFolder }.count
        let photosPerPage = options.columns * options.rows
        let totalPages = max(1, Int(ceil(Double(totalPhotos) / Double(photosPerPage))))

        let usableWidth = options.pageSize.width - options.margin * 2
        let headerHeight: CGFloat = options.headerText.isEmpty ? 0 : 30
        let footerHeight: CGFloat = options.footerText.isEmpty ? 0 : 20
        let filenameHeight: CGFloat = options.showFilename ? 14 : 0
        let ratingHeight: CGFloat = options.showRating ? 10 : 0
        let exifHeight: CGFloat = options.showExif ? 10 : 0
        let labelHeight = filenameHeight + ratingHeight + exifHeight

        let usableHeight = options.pageSize.height - options.margin * 2 - headerHeight - footerHeight
        let cellWidth = (usableWidth - CGFloat(options.columns - 1) * options.spacing) / CGFloat(options.columns)
        let cellHeight = (usableHeight - CGFloat(options.rows - 1) * options.spacing) / CGFloat(options.rows)
        let thumbHeight = cellHeight - labelHeight

        let filteredPhotos = photos.filter { !$0.isFolder && !$0.isParentFolder }
        var photoIndex = 0

        for page in 0..<totalPages {
            context.beginPDFPage(nil)

            // Background
            context.setFillColor(options.backgroundColor.cgColor)
            context.fill(CGRect(origin: .zero, size: options.pageSize))

            // Header
            if !options.headerText.isEmpty {
                let headerAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.boldSystemFont(ofSize: 14),
                    .foregroundColor: options.fontColor
                ]
                let headerStr = NSAttributedString(string: options.headerText, attributes: headerAttrs)
                let headerLine = CTLineCreateWithAttributedString(headerStr)
                let headerBounds = CTLineGetBoundsWithOptions(headerLine, [])

                context.saveGState()
                context.textMatrix = .identity
                context.textPosition = CGPoint(
                    x: options.margin,
                    y: options.pageSize.height - options.margin - headerBounds.height
                )
                CTLineDraw(headerLine, context)
                context.restoreGState()
            }

            // Footer
            if !options.footerText.isEmpty {
                let footerAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 8),
                    .foregroundColor: NSColor.gray
                ]
                let pageInfo = " — Page \(page + 1)/\(totalPages)"
                let footerStr = NSAttributedString(string: options.footerText + pageInfo, attributes: footerAttrs)
                let footerLine = CTLineCreateWithAttributedString(footerStr)

                context.saveGState()
                context.textMatrix = .identity
                context.textPosition = CGPoint(x: options.margin, y: options.margin - 5)
                CTLineDraw(footerLine, context)
                context.restoreGState()
            }

            // Photos
            let startY = options.pageSize.height - options.margin - headerHeight

            for row in 0..<options.rows {
                for col in 0..<options.columns {
                    guard photoIndex < filteredPhotos.count else { break }
                    let photo = filteredPhotos[photoIndex]

                    let x = options.margin + CGFloat(col) * (cellWidth + options.spacing)
                    let y = startY - CGFloat(row + 1) * (cellHeight + options.spacing) + options.spacing

                    // Thumbnail
                    if let image = loadThumbnail(photo: photo, maxSize: max(cellWidth, thumbHeight) * 2) {
                        let imgW = CGFloat(image.width)
                        let imgH = CGFloat(image.height)
                        let scale = min(cellWidth / imgW, thumbHeight / imgH)
                        let drawW = imgW * scale
                        let drawH = imgH * scale
                        let drawX = x + (cellWidth - drawW) / 2
                        let drawY = y + labelHeight + (thumbHeight - drawH) / 2

                        // Light border
                        context.setStrokeColor(NSColor.lightGray.cgColor)
                        context.setLineWidth(0.5)
                        context.stroke(CGRect(x: drawX - 0.5, y: drawY - 0.5, width: drawW + 1, height: drawH + 1))

                        context.draw(image, in: CGRect(x: drawX, y: drawY, width: drawW, height: drawH))
                    }

                    // Filename
                    if options.showFilename {
                        let nameAttrs: [NSAttributedString.Key: Any] = [
                            .font: NSFont.systemFont(ofSize: 7),
                            .foregroundColor: options.fontColor
                        ]
                        let nameStr = NSAttributedString(string: photo.fileNameWithExtension, attributes: nameAttrs)
                        let nameLine = CTLineCreateWithAttributedString(nameStr)

                        context.saveGState()
                        context.textMatrix = .identity
                        context.textPosition = CGPoint(x: x, y: y + ratingHeight + exifHeight)
                        CTLineDraw(nameLine, context)
                        context.restoreGState()
                    }

                    // Rating stars
                    if options.showRating && photo.rating > 0 {
                        let stars = String(repeating: "★", count: photo.rating) + String(repeating: "☆", count: 5 - photo.rating)
                        let starAttrs: [NSAttributedString.Key: Any] = [
                            .font: NSFont.systemFont(ofSize: 6),
                            .foregroundColor: NSColor.orange
                        ]
                        let starStr = NSAttributedString(string: stars, attributes: starAttrs)
                        let starLine = CTLineCreateWithAttributedString(starStr)

                        context.saveGState()
                        context.textMatrix = .identity
                        context.textPosition = CGPoint(x: x, y: y + exifHeight)
                        CTLineDraw(starLine, context)
                        context.restoreGState()
                    }

                    // EXIF info
                    if options.showExif, let exif = photo.exifData {
                        var info: [String] = []
                        if let iso = exif.iso { info.append("ISO\(iso)") }
                        if let ss = exif.shutterSpeed { info.append(ss) }
                        if let ap = exif.aperture { info.append(String(format: "f/%.1f", ap)) }
                        if !info.isEmpty {
                            let exifStr = NSAttributedString(
                                string: info.joined(separator: " "),
                                attributes: [
                                    .font: NSFont.systemFont(ofSize: 5),
                                    .foregroundColor: NSColor.gray
                                ]
                            )
                            let exifLine = CTLineCreateWithAttributedString(exifStr)
                            context.saveGState()
                            context.textMatrix = .identity
                            context.textPosition = CGPoint(x: x, y: y)
                            CTLineDraw(exifLine, context)
                            context.restoreGState()
                        }
                    }

                    photoIndex += 1
                    progress?(photoIndex, totalPhotos)
                }
            }

            context.endPDFPage()
        }

        context.closePDF()
        return pdfData as Data
    }

    /// 썸네일 로드 (PDF용 — 중간 해상도)
    private static func loadThumbnail(photo: PhotoItem, maxSize: CGFloat) -> CGImage? {
        let opts: [NSString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let source = CGImageSourceCreateWithURL(photo.jpgURL as CFURL, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else {
            return nil
        }
        return thumb
    }

    // MARK: - Page Size Presets

    static let pageSizes: [(name: String, size: NSSize)] = [
        ("A4 세로", NSSize(width: 595, height: 842)),
        ("A4 가로", NSSize(width: 842, height: 595)),
        ("A3 세로", NSSize(width: 842, height: 1191)),
        ("A3 가로", NSSize(width: 1191, height: 842)),
        ("Letter 세로", NSSize(width: 612, height: 792)),
        ("Letter 가로", NSSize(width: 792, height: 612)),
    ]
}
