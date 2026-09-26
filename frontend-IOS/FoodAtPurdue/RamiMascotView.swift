import SwiftUI
import Lottie

struct RamiMascotView: View {
    var size: CGFloat = 88

    var body: some View {
        LottieView(animation: .named("rami-sleeping"))
            .playing(loopMode: .loop)
            .frame(width: size, height: size)
    }
}
