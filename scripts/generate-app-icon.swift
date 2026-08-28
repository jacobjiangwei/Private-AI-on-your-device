#!/usr/bin/env swift

import AppKit
import Foundation

private extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: alpha
        )
    }
}

private enum IconPalette {
    static var background: NSColor { NSColor(hex: 0x252A31) }
    static var light: NSColor { NSColor(hex: 0xF4F8FF) }
    static var accent: NSColor { NSColor(hex: 0x72E6F4) }

    static var shellMiddle: NSColor {
        light.blended(withFraction: 0.11, of: accent) ?? light
    }

    static var shellShade: NSColor {
        light.blended(withFraction: 0.27, of: accent) ?? accent
    }

    static var visorTop: NSColor {
        background.blended(withFraction: 0.08, of: light) ?? background
    }

    static var visorBottom: NSColor {
        background.blended(withFraction: 0.22, of: NSColor.black) ?? background
    }
}

private func point(_ x: CGFloat, _ y: CGFloat, size: CGFloat) -> NSPoint {
    NSPoint(x: x * size, y: y * size)
}

private func mascotPath(size: CGFloat) -> NSBezierPath {
    let mascot = NSBezierPath()
    mascot.move(to: point(0.360, 0.320, size: size))
    mascot.line(to: point(0.245, 0.205, size: size))
    mascot.curve(
        to: point(0.290, 0.395, size: size),
        controlPoint1: point(0.235, 0.200, size: size),
        controlPoint2: point(0.265, 0.325, size: size)
    )
    mascot.curve(
        to: point(0.230, 0.500, size: size),
        controlPoint1: point(0.240, 0.415, size: size),
        controlPoint2: point(0.210, 0.455, size: size)
    )
    mascot.curve(
        to: point(0.275, 0.625, size: size),
        controlPoint1: point(0.205, 0.555, size: size),
        controlPoint2: point(0.225, 0.605, size: size)
    )
    mascot.curve(
        to: point(0.375, 0.705, size: size),
        controlPoint1: point(0.295, 0.680, size: size),
        controlPoint2: point(0.335, 0.705, size: size)
    )
    mascot.curve(
        to: point(0.455, 0.765, size: size),
        controlPoint1: point(0.390, 0.765, size: size),
        controlPoint2: point(0.430, 0.790, size: size)
    )
    mascot.curve(
        to: point(0.510, 0.725, size: size),
        controlPoint1: point(0.485, 0.770, size: size),
        controlPoint2: point(0.505, 0.745, size: size)
    )
    mascot.curve(
        to: point(0.580, 0.795, size: size),
        controlPoint1: point(0.530, 0.785, size: size),
        controlPoint2: point(0.565, 0.820, size: size)
    )
    mascot.curve(
        to: point(0.645, 0.725, size: size),
        controlPoint1: point(0.610, 0.815, size: size),
        controlPoint2: point(0.640, 0.770, size: size)
    )
    mascot.curve(
        to: point(0.725, 0.685, size: size),
        controlPoint1: point(0.680, 0.765, size: size),
        controlPoint2: point(0.720, 0.735, size: size)
    )
    mascot.curve(
        to: point(0.795, 0.585, size: size),
        controlPoint1: point(0.770, 0.665, size: size),
        controlPoint2: point(0.805, 0.625, size: size)
    )
    mascot.curve(
        to: point(0.785, 0.440, size: size),
        controlPoint1: point(0.825, 0.525, size: size),
        controlPoint2: point(0.815, 0.475, size: size)
    )
    mascot.curve(
        to: point(0.705, 0.335, size: size),
        controlPoint1: point(0.765, 0.375, size: size),
        controlPoint2: point(0.740, 0.345, size: size)
    )
    mascot.curve(
        to: point(0.575, 0.285, size: size),
        controlPoint1: point(0.665, 0.300, size: size),
        controlPoint2: point(0.615, 0.285, size: size)
    )
    mascot.curve(
        to: point(0.470, 0.300, size: size),
        controlPoint1: point(0.535, 0.255, size: size),
        controlPoint2: point(0.495, 0.270, size: size)
    )
    mascot.curve(
        to: point(0.405, 0.345, size: size),
        controlPoint1: point(0.445, 0.300, size: size),
        controlPoint2: point(0.425, 0.330, size: size)
    )
    mascot.curve(
        to: point(0.360, 0.320, size: size),
        controlPoint1: point(0.385, 0.330, size: size),
        controlPoint2: point(0.375, 0.320, size: size)
    )
    mascot.close()
    return mascot
}

private func visorPath(size: CGFloat) -> NSBezierPath {
    NSBezierPath(
        roundedRect: NSRect(
            x: size * 0.325,
            y: size * 0.400,
            width: size * 0.430,
            height: size * 0.270
        ),
        xRadius: size * 0.125,
        yRadius: size * 0.125
    )
}

private func drawMascot(size: CGFloat, detailed: Bool) {
    let mascot = mascotPath(size: size)

    NSGraphicsContext.saveGraphicsState()
    let groundShadow = NSShadow()
    groundShadow.shadowColor = NSColor.black.withAlphaComponent(0.48)
    groundShadow.shadowBlurRadius = size * 0.060
    groundShadow.shadowOffset = NSSize(width: 0, height: -size * 0.015)
    groundShadow.set()
    NSColor.black.withAlphaComponent(0.22).setFill()
    NSBezierPath(
        ovalIn: NSRect(
            x: size * 0.265,
            y: size * 0.195,
            width: size * 0.505,
            height: size * 0.095
        )
    ).fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.44)
    shadow.shadowBlurRadius = size * 0.055
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.030)
    shadow.set()
    NSGradient(
        starting: IconPalette.light,
        ending: IconPalette.shellShade
    )?.draw(in: mascot, angle: -62)
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    mascot.addClip()
    NSGradient(
        starting: IconPalette.light.withAlphaComponent(0.92),
        ending: IconPalette.light.withAlphaComponent(0)
    )?.draw(
        in: NSBezierPath(
            ovalIn: NSRect(
                x: size * 0.190,
                y: size * 0.540,
                width: size * 0.510,
                height: size * 0.390
            )
        ),
        relativeCenterPosition: .zero
    )
    NSGradient(
        starting: IconPalette.accent.withAlphaComponent(0.50),
        ending: IconPalette.accent.withAlphaComponent(0)
    )?.draw(
        in: NSBezierPath(
            ovalIn: NSRect(
                x: size * 0.325,
                y: size * 0.155,
                width: size * 0.570,
                height: size * 0.450
            )
        ),
        relativeCenterPosition: .zero
    )
    NSGradient(
        starting: IconPalette.background.withAlphaComponent(0.18),
        ending: IconPalette.background.withAlphaComponent(0)
    )?.draw(
        in: NSBezierPath(
            ovalIn: NSRect(
                x: size * 0.070,
                y: size * 0.115,
                width: size * 0.430,
                height: size * 0.430
            )
        ),
        relativeCenterPosition: .zero
    )
    NSGraphicsContext.restoreGraphicsState()

    mascot.lineWidth = max(size * 0.006, 0.8)
    IconPalette.light.withAlphaComponent(0.72).setStroke()
    mascot.stroke()

    if detailed {
        let grooves = NSBezierPath()
        grooves.move(to: point(0.395, 0.785, size: size))
        grooves.curve(
            to: point(0.420, 0.690, size: size),
            controlPoint1: point(0.390, 0.750, size: size),
            controlPoint2: point(0.435, 0.730, size: size)
        )
        grooves.move(to: point(0.585, 0.775, size: size))
        grooves.curve(
            to: point(0.570, 0.690, size: size),
            controlPoint1: point(0.600, 0.745, size: size),
            controlPoint2: point(0.555, 0.725, size: size)
        )
        grooves.lineWidth = max(size * 0.009, 1)
        grooves.lineCapStyle = .round
        IconPalette.background.withAlphaComponent(0.10).setStroke()
        grooves.stroke()

    }

    let visor = visorPath(size: size)
    NSGraphicsContext.saveGraphicsState()
    let visorGlow = NSShadow()
    visorGlow.shadowColor = IconPalette.accent.withAlphaComponent(0.50)
    visorGlow.shadowBlurRadius = size * 0.028
    visorGlow.shadowOffset = .zero
    visorGlow.set()
    NSGradient(
        starting: IconPalette.visorTop,
        ending: IconPalette.visorBottom
    )?.draw(in: visor, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    visor.addClip()
    NSGradient(
        starting: IconPalette.accent.withAlphaComponent(0.24),
        ending: IconPalette.accent.withAlphaComponent(0)
    )?.draw(
        in: NSBezierPath(
            ovalIn: NSRect(
                x: size * 0.325,
                y: size * 0.335,
                width: size * 0.430,
                height: size * 0.265
            )
        ),
        relativeCenterPosition: .zero
    )
    NSGraphicsContext.restoreGraphicsState()

    visor.lineWidth = max(size * 0.007, 0.85)
    IconPalette.accent.withAlphaComponent(0.62).setStroke()
    visor.stroke()

    let featureWidth = max(size * (detailed ? 0.011 : 0.016), 1.05)

    let leftEye = NSBezierPath(
        ovalIn: NSRect(
            x: size * 0.390,
            y: size * 0.480,
            width: size * 0.055,
            height: size * 0.088
        )
    )
    let rightEye = NSBezierPath(
        ovalIn: NSRect(
            x: size * 0.610,
            y: size * 0.480,
            width: size * 0.055,
            height: size * 0.088
        )
    )

    NSGraphicsContext.saveGraphicsState()
    let faceGlow = NSShadow()
    faceGlow.shadowColor = IconPalette.accent.withAlphaComponent(0.68)
    faceGlow.shadowBlurRadius = size * 0.018
    faceGlow.shadowOffset = .zero
    faceGlow.set()
    NSGradient(
        starting: IconPalette.light,
        ending: IconPalette.accent
    )?.draw(in: leftEye, angle: -90)
    NSGradient(
        starting: IconPalette.light,
        ending: IconPalette.accent
    )?.draw(in: rightEye, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    if detailed {
        let eyeShine = size * 0.012
        IconPalette.light.setFill()
        NSBezierPath(
            ovalIn: NSRect(
                x: size * 0.401,
                y: size * 0.546,
                width: eyeShine,
                height: eyeShine
            )
        ).fill()
        NSBezierPath(
            ovalIn: NSRect(
                x: size * 0.621,
                y: size * 0.546,
                width: eyeShine,
                height: eyeShine
            )
        ).fill()
    }

    let smile = NSBezierPath()
    smile.move(to: point(0.492, 0.455, size: size))
    smile.curve(
        to: point(0.563, 0.455, size: size),
        controlPoint1: point(0.507, 0.425, size: size),
        controlPoint2: point(0.548, 0.425, size: size)
    )
    smile.lineWidth = featureWidth
    smile.lineCapStyle = .round
    IconPalette.accent.setStroke()
    smile.stroke()
}

let output = CommandLine.arguments.dropFirst().first.map {
    URL(fileURLWithPath: $0, isDirectory: true)
} ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

let icons: [(String, Int)] = [
    ("AppIcon-16.png", 16),
    ("AppIcon-16@2x.png", 32),
    ("AppIcon-32.png", 32),
    ("AppIcon-32@2x.png", 64),
    ("AppIcon-128.png", 128),
    ("AppIcon-128@2x.png", 256),
    ("AppIcon-256.png", 256),
    ("AppIcon-256@2x.png", 512),
    ("AppIcon-512.png", 512),
    ("AppIcon-512@2x.png", 1024)
]

try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

for (name, pixels) in icons {
    let size = CGFloat(pixels)
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Unable to create bitmap for \(name)")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics

    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()

    let detailed = pixels >= 64
    let inset = size * 0.055
    let backgroundRect = NSRect(
        x: inset,
        y: inset,
        width: size - inset * 2,
        height: size - inset * 2
    )
    let background = NSBezierPath(
        roundedRect: backgroundRect,
        xRadius: size * 0.215,
        yRadius: size * 0.215
    )
    IconPalette.background.setFill()
    background.fill()

    drawMascot(size: size, detailed: detailed)

    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Unable to encode \(name)")
    }
    try png.write(to: output.appendingPathComponent(name), options: .atomic)
}
