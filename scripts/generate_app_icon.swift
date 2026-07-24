#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2 else {
    fputs("usage: generate_app_icon.swift <output.png>\n", stderr)
    exit(64)
}

let pixelSize = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
guard let context = CGContext(
    data: nil,
    width: pixelSize,
    height: pixelSize,
    bitsPerComponent: 8,
    bytesPerRow: pixelSize * 4,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else {
    fatalError("Could not create bitmap context")
}

// Trabalhamos nas mesmas coordenadas 108×108 do adaptive icon Android.
context.translateBy(x: 0, y: CGFloat(pixelSize))
context.scaleBy(x: CGFloat(pixelSize) / 108, y: -CGFloat(pixelSize) / 108)
context.setFillColor(CGColor(red: 15 / 255, green: 118 / 255, blue: 110 / 255, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: 108, height: 108))

context.saveGState()
context.translateBy(x: 20, y: 27.75)
context.scaleBy(x: 0.309, y: 0.309)
context.translateBy(x: 18, y: 16)
context.translateBy(x: 74, y: 70)
context.rotate(by: -12 * .pi / 180)
context.translateBy(x: -74, y: -70)

let white = CGColor(gray: 1, alpha: 1)
context.setStrokeColor(white)
context.setFillColor(white)
context.setLineCap(.round)
context.setLineJoin(.round)

context.setLineWidth(10)
context.addPath(CGPath(roundedRect: CGRect(x: 12, y: 8, width: 120, height: 120),
                       cornerWidth: 18, cornerHeight: 18, transform: nil))
context.strokePath()

context.addPath(CGPath(roundedRect: CGRect(x: 28, y: 30, width: 34, height: 28),
                       cornerWidth: 4, cornerHeight: 4, transform: nil))
context.fillPath()

func strokeLine(from start: CGPoint, to end: CGPoint, width: CGFloat) {
    context.setLineWidth(width)
    context.move(to: start)
    context.addLine(to: end)
    context.strokePath()
}

strokeLine(from: CGPoint(x: 28, y: 74), to: CGPoint(x: 64, y: 74), width: 10)
strokeLine(from: CGPoint(x: 28, y: 96), to: CGPoint(x: 56, y: 96), width: 10)

context.setLineWidth(20)
context.move(to: CGPoint(x: 92, y: 78))
context.addLine(to: CGPoint(x: 118, y: 104))
context.addLine(to: CGPoint(x: 162, y: 44))
context.strokePath()

context.setLineWidth(8)
context.move(to: CGPoint(x: 154, y: 30))
context.addCurve(to: CGPoint(x: 180, y: 56),
                 control1: CGPoint(x: 167, y: 34), control2: CGPoint(x: 176, y: 43))
context.strokePath()
context.move(to: CGPoint(x: 166, y: 18))
context.addCurve(to: CGPoint(x: 202, y: 56),
                 control1: CGPoint(x: 184, y: 24), control2: CGPoint(x: 197, y: 38))
context.strokePath()
context.restoreGState()

guard let image = context.makeImage() else { fatalError("Could not render app icon") }
let outputURL = URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL
guard let destination = CGImageDestinationCreateWithURL(
    outputURL, UTType.png.identifier as CFString, 1, nil
) else {
    fatalError("Could not create PNG destination")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Could not write PNG") }
