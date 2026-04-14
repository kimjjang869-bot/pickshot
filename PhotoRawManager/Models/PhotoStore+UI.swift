import SwiftUI
import Foundation

extension PhotoStore {
    func showToastMessage(_ msg: String) {
        toastMessage = msg
        showToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.showToast = false
        }
    }

    func setLayoutMode(_ mode: LayoutMode) {
        layoutMode = mode
        defaults.set(mode.rawValue, forKey: layoutModeKey)
    }

    /// 그리드 열 수 재계산 — 윈도우 실제 폭 기반 (보조 모니터 대응)
    func recalcColumnsFromRatio() {
        // keyWindow가 있으면 해당 윈도우 기준, 없으면 모든 윈도우 중 가장 큰 것
        let windowW: CGFloat
        if let kw = NSApp.keyWindow {
            windowW = kw.frame.width
        } else if let mainW = NSApp.windows.first(where: { $0.isVisible && !$0.isMiniaturized })?.frame.width {
            windowW = mainW
        } else {
            windowW = NSScreen.main?.frame.width ?? 1440
        }
        let leftW = windowW * hSplitRatio
        let size = thumbnailSize
        let spacing: CGFloat = 12
        let cellWidth = size + spacing
        let cols = max(1, Int((leftW + spacing) / cellWidth))
        if actualColumnsPerRow != cols {
            actualColumnsPerRow = cols
        }
    }

    func toggleMetadataOverlay() {
        showMetadataOverlay.toggle()
    }
}
