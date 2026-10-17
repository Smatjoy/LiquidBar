import SwiftUI

/// The small mark Liqoria puts after the artist (`AudioQualityView` with
/// `onlySymbols`): the lossless waves for Lossless and Hi-Res Lossless, two
/// facing D's for Dolby Atmos. Liqoria uses a bitmap and a custom shape;
/// these are LiquidBar's own vector drawings, tinted like the artist line.
struct AudioQualityBadge: View {
  let quality: AudioQuality

  var body: some View {
    Group {
      switch quality {
      case .lossless, .hiResLossless:
        LosslessWaves()
          .frame(width: 14, height: 9)
      case .dolbyAtmos:
        // ◗◖: the round sides meet in the middle.
        HStack(spacing: 1) {
          DolbyD(facingRight: true)
          DolbyD(facingRight: false)
        }
        .frame(width: 12, height: 9)
      }
    }
    .accessibilityElement()
    .accessibilityLabel(label)
  }

  private var label: String {
    switch quality {
    case .lossless: "Lossless"
    case .hiResLossless: "Hi-Res Lossless"
    case .dolbyAtmos: "Dolby Atmos"
    }
  }
}

/// Three sine periods side by side, each heavier on its falling stroke,
/// merged into one outline so overlaps don't double up under a translucent
/// tint.
private nonisolated struct LosslessWaves: Shape {
  func path(in rect: CGRect) -> Path {
    let shift = rect.width * 0.13
    let waveWidth = rect.width - shift * 2
    var outline = Path()
    for index in 0..<3 {
      let x0 = rect.minX + CGFloat(index) * shift
      // The whole wave, thin, and its falling middle, bold.
      let thin = wave(from: x0, width: waveWidth, in: rect, range: 0...1)
        .strokedPath(StrokeStyle(lineWidth: 0.5, lineCap: .round))
      let bold = wave(from: x0, width: waveWidth, in: rect, range: 0.25...0.75)
        .strokedPath(StrokeStyle(lineWidth: 1, lineCap: .round))
      outline = outline.union(thin).union(bold)
    }
    return outline
  }

  /// One period from the midline: up to the crest, down to the trough, back.
  private func wave(from x0: CGFloat, width: CGFloat, in rect: CGRect, range: ClosedRange<CGFloat>) -> Path {
    var path = Path()
    let amplitude = rect.height / 2 - 0.8
    let steps = 24
    for step in 0...steps {
      let t = range.lowerBound + (range.upperBound - range.lowerBound) * CGFloat(step) / CGFloat(steps)
      let point = CGPoint(x: x0 + t * width, y: rect.midY - amplitude * sin(.pi * 2 * t))
      step == 0 ? path.move(to: point) : path.addLine(to: point)
    }
    return path
  }
}

/// A capital D: a flat edge and a half-round side, mirrored for the pair.
private nonisolated struct DolbyD: Shape {
  var facingRight: Bool

  func path(in rect: CGRect) -> Path {
    var path = Path()
    let radius = min(rect.width, rect.height / 2)
    if facingRight {
      path.move(to: CGPoint(x: rect.minX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
      path.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.midY), radius: radius,
                  startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
      path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
    } else {
      path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.minY))
      path.addArc(center: CGPoint(x: rect.minX + radius, y: rect.midY), radius: radius,
                  startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: true)
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    }
    path.closeSubpath()
    return path
  }
}
