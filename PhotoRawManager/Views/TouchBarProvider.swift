import SwiftUI
import AppKit

// MARK: - TouchBar Integration

/// Provides NSTouchBar items for the photo selector app:
/// - Current photo thumbnail
/// - Star rating buttons (1-5)
/// - Quick navigation arrows

extension NSTouchBarItem.Identifier {
    static let photoThumbnail = NSTouchBarItem.Identifier("com.pickshot.touchbar.thumbnail")
    static let starRating = NSTouchBarItem.Identifier("com.pickshot.touchbar.starRating")
    static let navigation = NSTouchBarItem.Identifier("com.pickshot.touchbar.navigation")
    static let spacePick = NSTouchBarItem.Identifier("com.pickshot.touchbar.spacePick")
}

extension NSTouchBar.CustomizationIdentifier {
    static let photoSelector = NSTouchBar.CustomizationIdentifier("com.pickshot.touchbar")
}

class TouchBarProvider: NSObject, NSTouchBarDelegate {
    weak var store: PhotoStore?

    func makeTouchBar() -> NSTouchBar {
        let touchBar = NSTouchBar()
        touchBar.delegate = self
        touchBar.customizationIdentifier = .photoSelector
        touchBar.defaultItemIdentifiers = [
            .photoThumbnail,
            .fixedSpaceSmall,
            .starRating,
            .fixedSpaceSmall,
            .spacePick,
            .flexibleSpace,
            .navigation
        ]
        touchBar.customizationAllowedItemIdentifiers = [
            .photoThumbnail,
            .starRating,
            .navigation,
            .spacePick
        ]
        return touchBar
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        switch identifier {
        case .photoThumbnail:
            return makeThumbnailItem(identifier: identifier)
        case .starRating:
            return makeStarRatingItem(identifier: identifier)
        case .navigation:
            return makeNavigationItem(identifier: identifier)
        case .spacePick:
            return makeSpacePickItem(identifier: identifier)
        default:
            return nil
        }
    }

    // MARK: - Thumbnail Item

    private func makeThumbnailItem(identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: identifier)
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown

        if let photo = store?.selectedPhoto {
            // TouchBar용 소형 썸네일만 로딩 (풀사이즈 방지)
            let image: NSImage? = {
                guard let source = CGImageSourceCreateWithURL(photo.jpgURL as CFURL, nil) else { return nil }
                let opts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 100,
                    kCGImageSourceCreateThumbnailWithTransform: true
                ]
                guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { return nil }
                return NSImage(cgImage: thumb, size: NSSize(width: thumb.width, height: thumb.height))
            }()
            imageView.image = image
            imageView.toolTip = photo.fileName
        } else {
            imageView.image = NSImage(systemSymbolName: "photo", accessibilityDescription: "No photo")
        }

        // TouchBar height is 30pt
        imageView.widthAnchor.constraint(equalToConstant: 50).isActive = true
        imageView.heightAnchor.constraint(equalToConstant: 30).isActive = true

        item.view = imageView
        item.customizationLabel = "Photo Thumbnail"
        return item
    }

    // MARK: - Star Rating Item

    private func makeStarRatingItem(identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: identifier)

        let stackView = NSStackView()
        stackView.orientation = .horizontal
        stackView.spacing = 2

        for star in 1...5 {
            let button = NSButton(title: String(star), target: self, action: #selector(starRatingTapped(_:)))
            button.tag = star
            let currentRating = store?.selectedPhoto?.rating ?? 0
            let symbolName = star <= currentRating ? "star.fill" : "star"
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "\(star) star")
            button.title = ""
            button.bezelStyle = .rounded
            button.isBordered = false
            if star <= currentRating {
                button.contentTintColor = .systemYellow
            }
            stackView.addArrangedSubview(button)
        }

        item.view = stackView
        item.customizationLabel = "Star Rating"
        return item
    }

    @objc private func starRatingTapped(_ sender: NSButton) {
        let rating = sender.tag
        if let store = store {
            if store.selectionCount > 1 {
                store.setRatingForSelected(rating)
            } else if let id = store.selectedPhotoID {
                store.setRating(rating, for: id)
            }
        }
    }

    // MARK: - Navigation Item

    private func makeNavigationItem(identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: identifier)

        let stackView = NSStackView()
        stackView.orientation = .horizontal
        stackView.spacing = 4

        let prevButton = NSButton(image: NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Previous")!,
                                   target: self, action: #selector(navigatePrevious))
        prevButton.bezelStyle = .rounded
        prevButton.isBordered = false

        let nextButton = NSButton(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Next")!,
                                   target: self, action: #selector(navigateNext))
        nextButton.bezelStyle = .rounded
        nextButton.isBordered = false

        stackView.addArrangedSubview(prevButton)
        stackView.addArrangedSubview(nextButton)

        item.view = stackView
        item.customizationLabel = "Navigation"
        return item
    }

    @objc private func navigatePrevious() {
        store?.selectLeft()
    }

    @objc private func navigateNext() {
        store?.selectRight()
    }

    // MARK: - Space Pick Item

    private func makeSpacePickItem(identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: identifier)

        let isPicked = store?.selectedPhoto?.isSpacePicked ?? false
        let symbolName = isPicked ? "checkmark.circle.fill" : "checkmark.circle"
        let button = NSButton(image: NSImage(systemSymbolName: symbolName, accessibilityDescription: "Space Pick")!,
                               target: self, action: #selector(toggleSpacePick))
        button.bezelStyle = .rounded
        button.isBordered = false
        if isPicked {
            button.contentTintColor = .systemRed
        }

        item.view = button
        item.customizationLabel = "Space Pick"
        return item
    }

    @objc private func toggleSpacePick() {
        if let store = store {
            if store.selectionCount > 1 {
                store.toggleSpacePickForSelected()
            } else if let id = store.selectedPhotoID {
                store.toggleSpacePick(for: id)
            }
        }
    }
}
