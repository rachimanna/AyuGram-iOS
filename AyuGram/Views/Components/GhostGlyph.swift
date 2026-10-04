import SwiftUI
import UIKit

/// Ghost shape used for the ghost-mode toggle and the splash screen (same drawing as the app icon).
struct GhostShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let bodyW = w * 0.86
        let left = rect.midX - bodyW / 2
        let top = rect.minY + h * 0.04
        let bottom = rect.maxY - h * 0.02
        let radius = bodyW / 2
        var p = Path()
        p.move(to: CGPoint(x: left, y: top + radius))
        p.addArc(center: CGPoint(x: rect.midX, y: top + radius), radius: radius,
                 startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: left + bodyW, y: bottom - h * 0.1))
        // three bumps along the bottom
        let bump = bodyW / 3
        for i in (0..<3).reversed() {
            let x0 = left + CGFloat(i + 1) * bump
            let x1 = left + CGFloat(i) * bump
            p.addQuadCurve(to: CGPoint(x: x1, y: bottom - h * 0.1),
                           control: CGPoint(x: (x0 + x1) / 2, y: bottom + h * 0.08))
        }
        p.closeSubpath()
        return p
    }
}

struct GhostGlyph: View {
    var active: Bool = true

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                GhostShape().fill(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                HStack(spacing: s * 0.17) {
                    Capsule().frame(width: s * 0.13, height: s * 0.18)
                    Capsule().frame(width: s * 0.13, height: s * 0.18)
                }
                .foregroundStyle(Color(uiColor: .systemBackground))
                .offset(y: -s * 0.08)
                if !active {
                    Rectangle()
                        .fill(.secondary)
                        .frame(width: s * 1.1, height: max(1.5, s * 0.07))
                        .rotationEffect(.degrees(-40))
                }
            }
            .frame(width: s, height: s)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
