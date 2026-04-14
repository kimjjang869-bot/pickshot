import SwiftUI

/// 별점 인터랙티브 뷰 (탭하여 별점 부여)
struct StarRatingView: View {
    let rating: Int
    let onRate: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
                    .font(.system(size: 16))
                    .foregroundColor(star <= rating ? AppTheme.starGold : .gray.opacity(0.3))
                    .onTapGesture {
                        onRate(star)
                    }
            }
        }
    }
}

/// 별점 읽기 전용 컴팩트 뷰 (셀/필름스트립/타임라인용)
/// - compact=true: 채워진 별만 표시 (rating==0일 때 비표시)
/// - compact=false: 5개 별 모두 표시 (빈 별 포함)
struct StarDisplayView: View {
    let rating: Int
    var size: CGFloat = 8
    var compact: Bool = true

    var body: some View {
        if compact {
            if rating > 0 {
                HStack(spacing: 0) {
                    ForEach(0..<rating, id: \.self) { _ in
                        Image(systemName: "star.fill")
                            .font(.system(size: size))
                            .foregroundColor(AppTheme.starGold)
                    }
                }
            }
        } else {
            HStack(spacing: 0) {
                ForEach(1...5, id: \.self) { i in
                    Image(systemName: i <= rating ? "star.fill" : "star")
                        .font(.system(size: size))
                        .foregroundColor(i <= rating ? AppTheme.starGold : AppTheme.starEmpty.opacity(0.4))
                }
            }
        }
    }
}
