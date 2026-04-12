import SwiftUI

struct FilmstripView: View {
    @EnvironmentObject var store: PhotoStore
    @AppStorage("filmstripHeight") private var filmstripHeight: Double = 120
    @State private var scrollMonitor: Any?

    /// Convert vertical mouse wheel to horizontal scroll in filmstrip
    private func setupVerticalToHorizontalScroll() {
        if let existing = scrollMonitor { NSEvent.removeMonitor(existing); scrollMonitor = nil }
        let height = filmstripHeight
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            // Only intercept if mouse is in the filmstrip area (bottom of window)
            guard let window = event.window,
                  let contentView = window.contentView else { return event }
            let mouseY = contentView.convert(event.locationInWindow, from: nil).y
            if mouseY < height + 20 {
                let deltaY = event.scrollingDeltaY
                if abs(deltaY) > abs(event.scrollingDeltaX) && abs(deltaY) > 0.5 {
                    // Create a new horizontal scroll event
                    if let cgEvent = event.cgEvent?.copy() {
                        // Swap deltaY → deltaX
                        cgEvent.setDoubleValueField(.scrollWheelEventDeltaAxis2, value: Double(-deltaY))
                        cgEvent.setDoubleValueField(.scrollWheelEventDeltaAxis1, value: 0)
                        if let newEvent = NSEvent(cgEvent: cgEvent) {
                            window.sendEvent(newEvent)
                            return nil  // Consume original
                        }
                    }
                }
            }
            return event
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Resize handle
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(height: 4)
                .frame(maxWidth: .infinity)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.gray.opacity(0.6))
                        .frame(width: 40, height: 3)
                )
                .contentShape(Rectangle())
                .gesture(DragGesture()
                    .onChanged { value in
                        filmstripHeight = max(80, min(300, filmstripHeight - value.translation.height))
                    }
                )
                .onHover { hovering in
                    if hovering { NSCursor.resizeUpDown.push() }
                    else { NSCursor.pop() }
                }

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: true) {
                    LazyHStack(spacing: 4) {
                        ForEach(store.filteredPhotos) { photo in
                            FilmstripCell(
                                photo: photo,
                                isSelected: store.selectedPhotoID == photo.id,
                                cellHeight: filmstripHeight - 20
                            )
                            .id(photo.id)
                            .onTapGesture(count: 2) {
                                // Double-click: enter folder
                                if photo.isFolder || photo.isParentFolder {
                                    store.loadFolder(photo.jpgURL, restoreRatings: true)
                                }
                            }
                            .onTapGesture(count: 1) {
                                // Single click: select (folders too)
                                if photo.isFolder || photo.isParentFolder {
                                    store.selectedPhotoID = photo.id
                                    store.selectedPhotoIDs = [photo.id]
                                } else {
                                    let flags = NSEvent.modifierFlags
                                    store.selectPhoto(photo.id, cmdKey: flags.contains(.command), shiftKey: flags.contains(.shift))
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .frame(height: filmstripHeight)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.95))
                .scrollIndicators(.visible)
                .onAppear { setupVerticalToHorizontalScroll() }
                .onDisappear {
                    if let monitor = scrollMonitor {
                        NSEvent.removeMonitor(monitor)
                        scrollMonitor = nil
                    }
                }
                .onChange(of: store.scrollTrigger) { _ in
                    guard let id = store.selectedPhotoID else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
                .onChange(of: store.selectedPhotoID) { newID in
                    guard let id = newID else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }
}

struct FilmstripCell: View {
    let photo: PhotoItem
    let isSelected: Bool
    var cellHeight: CGFloat = 100
    @State private var isHovered = false

    private var cellWidth: CGFloat { cellHeight * 1.3 }
    private var imgHeight: CGFloat { cellHeight * 0.7 }

    var body: some View {
        VStack(spacing: 2) {
            ZStack(alignment: .topTrailing) {
                AsyncThumbnailView(url: photo.jpgURL)
                    .frame(width: cellWidth, height: imgHeight)
                    .clipped()
                    .cornerRadius(4)

                // SP badge (red, prominent)
                if photo.isSpacePicked {
                    Text("SP")
                        .font(.system(size: 8, weight: .black))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.red.opacity(0.9))
                        .cornerRadius(3)
                        .padding(3)
                }

                // RAW/format badge (top-left)
                if photo.hasRAW, let rawURL = photo.rawURL {
                    Text(rawURL.pathExtension.uppercased())
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(AppTheme.rawBadge.opacity(0.85))
                        .cornerRadius(2)
                        .padding(3)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }

                // G select badge
                if photo.isGSelected {
                    Text("G")
                        .font(.system(size: 8, weight: .black))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.9))
                        .cornerRadius(3)
                        .padding(3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }

            Text(photo.fileName)
                .font(.system(size: 9))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(isSelected ? .white : AppTheme.textSecondary)
                .frame(width: cellWidth)

            // Star rating
            if photo.rating > 0 {
                HStack(spacing: 0) {
                    Text(String(repeating: "\u{2605}", count: photo.rating))
                        .font(.system(size: 7))
                        .foregroundColor(AppTheme.starFilled)
                }
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(
                    isSelected ? AppTheme.accent.opacity(0.3) :
                    isHovered ? Color.white.opacity(0.05) :
                    Color.clear
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(
                    photo.isSpacePicked && isSelected ? Color.red :
                    isSelected ? AppTheme.accent :
                    photo.isSpacePicked ? Color.red.opacity(0.6) :
                    Color.clear,
                    lineWidth: photo.isSpacePicked ? 3 : (isSelected ? 2.5 : 0)
                )
        )
        .onHover { isHovered = $0 }
    }
}
