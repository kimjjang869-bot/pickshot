import Foundation
import SwiftUI

/// 플로팅 보정 필의 확장 상태 공유 (ESC 키 처리용).
/// FloatingAdjustmentPill 이 expand/collapse 될 때마다 isExpanded 업데이트.
/// KeyEventHandling 이 ESC 시 이 상태 확인해서 fullscreen 닫기 vs 확장 닫기 분기.
final class AdjustmentPanelState: ObservableObject {
    static let shared = AdjustmentPanelState()
    @Published var isExpanded: Bool = false
}
