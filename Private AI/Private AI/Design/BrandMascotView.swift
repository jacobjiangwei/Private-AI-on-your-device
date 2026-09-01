import SwiftUI

/// The PrivateAI mascot: a friendly cloud-bubble robot rendered as vectors so it
/// scales crisply and can animate. It periodically blinks and flashes "star eyes"
/// with a gentle tilt, and stays perfectly still when Reduce Motion is enabled.
struct BrandMascotView: View {
    var size: CGFloat = 32
    /// When true, the mascot plays its idle liveliness loop.
    var isAnimated: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var blink = false
    @State private var sparkle = false
    @State private var tilt = false

    private var motionEnabled: Bool { isAnimated && !reduceMotion }

    var body: some View {
        MascotShape(blink: blink ? 1 : 0, sparkle: sparkle ? 1 : 0)
            .frame(width: size, height: size)
            .rotationEffect(.degrees(tilt ? 4 : -4))
            .accessibilityHidden(true)
            .onAppear { if motionEnabled { startLoop() } }
            .onChange(of: motionEnabled) { _, enabled in
                if enabled { startLoop() } else { reset() }
            }
    }

    private func reset() {
        blink = false
        sparkle = false
        tilt = false
    }

    private func startLoop() {
        withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
            tilt = true
        }
        scheduleBlink()
        scheduleSparkle()
    }

    private func scheduleBlink() {
        let delay = Double.random(in: 2.5...5.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard motionEnabled else { return }
            withAnimation(.easeInOut(duration: 0.09)) { blink = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.easeInOut(duration: 0.12)) { blink = false }
                scheduleBlink()
            }
        }
    }

    private func scheduleSparkle() {
        let delay = Double.random(in: 4.0...8.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard motionEnabled else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.5)) { sparkle = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                withAnimation(.easeOut(duration: 0.35)) { sparkle = false }
                scheduleSparkle()
            }
        }
    }
}

/// Vector drawing of the mascot. `blink` closes the eyes (0 open → 1 shut) and
/// `sparkle` shows star glints in the eyes (0 hidden → 1 shown).
private struct MascotShape: View {
    var blink: CGFloat
    var sparkle: CGFloat

    private let bodyGradient = LinearGradient(
        colors: [Color(red: 0.93, green: 0.97, blue: 1.0), Color(red: 0.80, green: 0.90, blue: 0.98)],
        startPoint: .top,
        endPoint: .bottom
    )
    private let faceGradient = LinearGradient(
        colors: [Color(red: 0.16, green: 0.19, blue: 0.24), Color(red: 0.09, green: 0.11, blue: 0.14)],
        startPoint: .top,
        endPoint: .bottom
    )
    private let eyeColor = Color(red: 0.55, green: 0.87, blue: 0.98)

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            ZStack {
                // Cloud-bubble body.
                cloudBody(w: w, h: h)
                    .fill(bodyGradient)
                    .overlay(
                        cloudBody(w: w, h: h)
                            .stroke(Color.white.opacity(0.7), lineWidth: max(0.5, w * 0.012))
                    )
                    .shadow(color: .black.opacity(0.12), radius: w * 0.03, y: w * 0.02)

                // Face screen.
                RoundedRectangle(cornerRadius: h * 0.20, style: .continuous)
                    .fill(faceGradient)
                    .frame(width: w * 0.62, height: h * 0.40)
                    .overlay(
                        RoundedRectangle(cornerRadius: h * 0.20, style: .continuous)
                            .stroke(eyeColor.opacity(0.55), lineWidth: max(0.5, w * 0.012))
                    )
                    .offset(y: -h * 0.06)

                // Eyes + smile grouped over the face.
                faceFeatures(w: w, h: h)
                    .offset(y: -h * 0.06)
            }
        }
    }

    private func cloudBody(w: CGFloat, h: CGFloat) -> Path {
        // A rounded blob with a speech-bubble tail at the lower left.
        Path { path in
            let rect = CGRect(x: w * 0.10, y: h * 0.14, width: w * 0.80, height: h * 0.60)
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: rect.height * 0.5, height: rect.height * 0.5))
            path.move(to: CGPoint(x: w * 0.30, y: h * 0.70))
            path.addLine(to: CGPoint(x: w * 0.18, y: h * 0.92))
            path.addLine(to: CGPoint(x: w * 0.44, y: h * 0.72))
            path.closeSubpath()
        }
    }

    private func faceFeatures(w: CGFloat, h: CGFloat) -> some View {
        let eyeW = w * 0.075
        let eyeH = h * 0.16
        let eyeSpacing = w * 0.20
        let eyeOpenHeight = eyeH * (1 - 0.9 * blink)

        return ZStack {
            ForEach([-1.0, 1.0], id: \.self) { side in
                ZStack {
                    Capsule()
                        .fill(eyeColor)
                        .frame(width: eyeW, height: max(eyeH * 0.1, eyeOpenHeight))
                    // Star sparkle overlay.
                    Image(systemName: "sparkle")
                        .font(.system(size: eyeH * 0.9, weight: .bold))
                        .foregroundStyle(.white)
                        .scaleEffect(0.4 + 0.6 * sparkle)
                        .opacity(Double(sparkle) * (1 - blink))
                }
                .offset(x: CGFloat(side) * eyeSpacing / 2, y: -h * 0.02)
            }

            // Smile.
            Path { path in
                let mid = CGPoint(x: 0, y: h * 0.10)
                path.move(to: CGPoint(x: mid.x - w * 0.06, y: mid.y))
                path.addQuadCurve(
                    to: CGPoint(x: mid.x + w * 0.06, y: mid.y),
                    control: CGPoint(x: mid.x, y: mid.y + h * 0.05)
                )
            }
            .stroke(eyeColor, style: StrokeStyle(lineWidth: max(0.8, w * 0.022), lineCap: .round))
            .frame(width: w, height: h)
        }
    }
}

#Preview {
    HStack(spacing: 24) {
        BrandMascotView(size: 44)
        BrandMascotView(size: 88)
    }
    .padding(40)
}
