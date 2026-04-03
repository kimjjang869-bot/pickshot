import SwiftUI

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
