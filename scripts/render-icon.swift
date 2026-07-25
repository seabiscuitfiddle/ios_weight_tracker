#!/usr/bin/env swift
//
// Regenerates the app icon:
//
//     swift scripts/render-icon.swift
//
// Writes App/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png.
//
// The icon is drawn in code rather than stored as an opaque binary for the same reason the
// palette lives in TallyCore: the numbers are reviewable. A colour or a proportion that drifts
// from the design system shows up in this diff instead of only in a screenshot.
//
// The subject is what the app is for — a body, an arrow, the same body taken in. Both figures
// stand the same height on the same line, and the head never changes size: this is one person
// over time, not a small person beside a large one. Weight is expressed where it actually
// shows, as the width of the waist, and the accent red lands on the figure being worked
// toward — the same colour the app already uses for the goal.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let size = 1024.0

/// The design system's tokens, from TallyCore's `Palette`.
func color(_ hex: UInt32) -> CGColor {
    CGColor(
        red: Double((hex >> 16) & 0xFF) / 255,
        green: Double((hex >> 8) & 0xFF) / 255,
        blue: Double(hex & 0xFF) / 255,
        alpha: 1
    )
}

let paper = color(0xF3F2F2)   // Palette.background
let ink = color(0x201E1D)     // Palette.text
let accent = color(0xEC3013)  // Palette.accent

/// Flips a top-left y into Core Graphics' bottom-left space, so every coordinate below can be
/// read the way the composition is described.
func y(_ top: Double) -> Double { size - top }
func p(_ x: Double, _ topY: Double) -> CGPoint { CGPoint(x: x, y: y(topY)) }

struct Figure {
    var centerX: Double
    var neckHalf: Double
    var shoulderHalf: Double
    /// The widest point. The one measurement that differs between the two figures.
    var waistHalf: Double
    var baseHalf: Double
    var headRadius: Double
    var neckY: Double
    var shoulderY: Double
    var waistY: Double
    var ground: Double
}

/// One closed outline: neck, sloped shoulders, a flank that bulges or draws in, a flat base.
/// Drawn symmetrically down the left side and back up the right.
func figurePath(_ f: Figure) -> CGPath {
    let path = CGMutablePath()
    let shoulderRun = f.shoulderY - f.neckY
    let waistRun = f.waistY - f.shoulderY
    let baseRun = f.ground - f.waistY

    path.move(to: p(f.centerX - f.neckHalf, f.neckY))
    path.addCurve(
        to: p(f.centerX - f.shoulderHalf, f.shoulderY),
        control1: p(f.centerX - f.neckHalf - 36, f.neckY),
        control2: p(f.centerX - f.shoulderHalf, f.shoulderY - shoulderRun * 0.5)
    )
    path.addCurve(
        to: p(f.centerX - f.waistHalf, f.waistY),
        control1: p(f.centerX - f.shoulderHalf, f.shoulderY + waistRun * 0.5),
        control2: p(f.centerX - f.waistHalf, f.waistY - waistRun * 0.5)
    )
    // Control points kept shallow here so the flank falls to the base without an ankle flare.
    path.addCurve(
        to: p(f.centerX - f.baseHalf, f.ground),
        control1: p(f.centerX - f.waistHalf, f.waistY + baseRun * 0.55),
        control2: p(f.centerX - f.baseHalf, f.ground - baseRun * 0.28)
    )
    path.addLine(to: p(f.centerX + f.baseHalf, f.ground))
    path.addCurve(
        to: p(f.centerX + f.waistHalf, f.waistY),
        control1: p(f.centerX + f.baseHalf, f.ground - baseRun * 0.28),
        control2: p(f.centerX + f.waistHalf, f.waistY + baseRun * 0.55)
    )
    path.addCurve(
        to: p(f.centerX + f.shoulderHalf, f.shoulderY),
        control1: p(f.centerX + f.waistHalf, f.waistY - waistRun * 0.5),
        control2: p(f.centerX + f.shoulderHalf, f.shoulderY + waistRun * 0.5)
    )
    path.addCurve(
        to: p(f.centerX + f.neckHalf, f.neckY),
        control1: p(f.centerX + f.shoulderHalf, f.shoulderY - shoulderRun * 0.5),
        control2: p(f.centerX + f.neckHalf + 36, f.neckY)
    )
    path.closeSubpath()

    // Overlaps the shoulders slightly. A gap would close up and turn muddy at 40 points.
    let headCenter = f.neckY - f.headRadius + 14
    path.addEllipse(in: CGRect(
        x: f.centerX - f.headRadius, y: y(headCenter + f.headRadius),
        width: f.headRadius * 2, height: f.headRadius * 2
    ))
    return path
}

/// A blunt arrow with square corners — the design system sets every radius to zero, and the
/// icon is the one place that rule would be most conspicuous to break.
func arrowPath(fromX: Double, toX: Double, centerY: Double,
               thickness: Double, headHalf: Double, headLength: Double) -> CGPath {
    let path = CGMutablePath()
    let shaftEnd = toX - headLength
    path.addRect(CGRect(
        x: fromX, y: y(centerY + thickness / 2),
        width: shaftEnd - fromX, height: thickness
    ))
    path.move(to: p(shaftEnd, centerY - headHalf))
    path.addLine(to: p(toX, centerY))
    path.addLine(to: p(shaftEnd, centerY + headHalf))
    path.closeSubpath()
    return path
}

/// The three appearances iOS 18 asks for.
///
/// Only the light one paints its own ground. The system supplies the background for the other
/// two — a dark gradient behind `dark`, the user's chosen tint behind `tinted` — so both are
/// drawn on transparency. Filling them anyway is the usual mistake: it produces a flat slab
/// sitting in a row of icons that all share the system's ground.
enum Appearance: String, CaseIterable {
    case light, dark, tinted

    var filename: String {
        switch self {
        case .light: "icon-1024.png"
        case .dark: "icon-1024-dark.png"
        case .tinted: "icon-1024-tinted.png"
        }
    }

    var background: CGColor? {
        switch self {
        case .light: paper
        case .dark, .tinted: nil
        }
    }

    /// `tinted` is greyscale on purpose: iOS maps luminance through the user's tint colour, so
    /// these values are not colours but positions in that ramp. Keeping the goal figure at full
    /// white and the starting figure well below it is what preserves the icon's one idea once
    /// the hues are gone.
    var beforeFigure: CGColor {
        switch self {
        case .light: ink
        case .dark: paper
        case .tinted: CGColor(gray: 0.52, alpha: 1)
        }
    }

    var afterFigure: CGColor {
        switch self {
        case .light, .dark: accent
        case .tinted: CGColor(gray: 1, alpha: 1)
        }
    }

    var furniture: CGColor {
        switch self {
        case .light: ink
        case .dark: paper
        case .tinted: CGColor(gray: 0.78, alpha: 1)
        }
    }
}

// The ground rule runs edge to edge: iOS masks the icon's corners, and a rule that stopped
// short would look like it had been trimmed rather than continued.
let ground = 838.0

let before = Figure(
    centerX: 296, neckHalf: 48, shoulderHalf: 150, waistHalf: 178, baseHalf: 156,
    headRadius: 94, neckY: 402, shoulderY: 492, waistY: 664, ground: ground
)
let after = Figure(
    centerX: 782, neckHalf: 40, shoulderHalf: 100, waistHalf: 84, baseHalf: 92,
    headRadius: 94, neckY: 402, shoulderY: 492, waistY: 664, ground: ground
)

func render(_ appearance: Appearance, to url: URL) {
    guard let context = CGContext(
        data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("could not create a bitmap context") }

    if let background = appearance.background {
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    }

    context.setFillColor(appearance.beforeFigure)
    context.addPath(figurePath(before))
    context.fillPath()

    context.setFillColor(appearance.afterFigure)
    context.addPath(figurePath(after))
    context.fillPath()

    context.setFillColor(appearance.furniture)
    context.addPath(arrowPath(
        fromX: 490, toX: 656, centerY: 590,
        thickness: 36, headHalf: 62, headLength: 70
    ))
    context.fillPath()

    context.setFillColor(appearance.furniture)
    context.fill(CGRect(x: 0, y: y(ground + 20), width: size, height: 20))

    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
          )
    else { fatalError("could not encode the icon") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("could not write \(url.path)")
    }
}

let iconSet = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("App/Resources/Assets.xcassets/AppIcon.appiconset")

for appearance in Appearance.allCases {
    let url = iconSet.appendingPathComponent(appearance.filename)
    render(appearance, to: url)
    print("Wrote \(url.lastPathComponent)")
}
