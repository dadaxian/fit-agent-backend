import SwiftUI

/// 私教卡通形象：使用生成的插画头像
struct CoachAvatar: View {
    var size: CGFloat = 64
    var isSpeaking: Bool = false

    var body: some View {
        Image("CoachAvatar")
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(
                Circle()
                    .stroke(Color.orange.opacity(0.3), lineWidth: 1)
            )
            .scaleEffect(isSpeaking ? 1.03 : 1.0)
            .animation(.easeInOut(duration: 0.35), value: isSpeaking)
    }
}

#Preview {
    HStack(spacing: 24) {
        CoachAvatar(size: 48)
        CoachAvatar(size: 64, isSpeaking: true)
        CoachAvatar(size: 80)
    }
    .padding()
}
