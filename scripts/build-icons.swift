#!/usr/bin/env swift
// Draws the Relay and Repro app icons with AppKit paths and writes one .iconset folder per app.
// Usage: build-icons.swift <output-directory>   (iconutil turns each .iconset into an .icns)
import AppKit

enum IconError: Error {
  case bitmap(Int)
  case encode(Int)
}

// Every pixel size an .icns needs, keyed by the filename iconutil expects.
let iconsetEntries: [(name: String, pixels: Int)] = [
  ("icon_16x16", 16), ("icon_16x16@2x", 32),
  ("icon_32x32", 32), ("icon_32x32@2x", 64),
  ("icon_128x128", 128), ("icon_128x128@2x", 256),
  ("icon_256x256", 256), ("icon_256x256@2x", 512),
  ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

/// Renders `design` onto a square bitmap and returns PNG data. Designs draw on a 1024-unit canvas.
func renderPNG(pixels: Int, design: (CGFloat) -> Void) throws -> Data {
  guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32),
    let context = NSGraphicsContext(bitmapImageRep: rep)
  else { throw IconError.bitmap(pixels) }

  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = context
  let scale = CGFloat(pixels) / 1024
  context.cgContext.scaleBy(x: scale, y: scale)
  design(CGFloat(pixels))
  NSGraphicsContext.restoreGraphicsState()

  guard let png = rep.representation(using: .png, properties: [:]) else { throw IconError.encode(pixels) }
  return png
}

/// Standard macOS app tile: an 824-unit rounded square with a gentle top-to-bottom gradient.
func drawTile(top: NSColor, bottom: NSColor) {
  let shape = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 186, yRadius: 186)
  // NSGradient angle 90 runs from the start color at the bottom to the end color at the top.
  NSGradient(starting: bottom, ending: top)?.draw(in: shape, angle: 90)
}

func drawRelay(pixels: CGFloat) {
  drawTile(
    top: NSColor(calibratedRed: 0.08, green: 0.72, blue: 0.65, alpha: 1),
    bottom: NSColor(calibratedRed: 0.15, green: 0.39, blue: 0.92, alpha: 1))

  // Three session tiles stacked back to front; the front tile carries two row bars.
  let front = NSRect(x: 250, y: 250, width: 420, height: 380)
  for (offset, alpha) in [(CGFloat(110), CGFloat(0.28)), (55, 0.5)] {
    NSColor.white.withAlphaComponent(alpha).setFill()
    NSBezierPath(roundedRect: front.offsetBy(dx: offset, dy: offset), xRadius: 64, yRadius: 64).fill()
  }
  NSColor.white.setFill()
  NSBezierPath(roundedRect: front, xRadius: 64, yRadius: 64).fill()

  // Row bars are too fine to read below 128px, so they only appear on larger sizes.
  if pixels >= 128 {
    NSColor(calibratedRed: 0.06, green: 0.46, blue: 0.43, alpha: 1).setFill()
    for bar in [NSRect(x: 320, y: 480, width: 280, height: 44), NSRect(x: 320, y: 390, width: 180, height: 44)] {
      NSBezierPath(roundedRect: bar, xRadius: 22, yRadius: 22).fill()
    }
  }
}

func drawRepro(pixels: CGFloat) {
  drawTile(
    top: NSColor(calibratedRed: 0.66, green: 0.33, blue: 0.97, alpha: 1),
    bottom: NSColor(calibratedRed: 0.43, green: 0.16, blue: 0.85, alpha: 1))

  // Erlenmeyer-style flask: neck, conical shoulders, and a rounded base.
  let flask = NSBezierPath()
  flask.move(to: NSPoint(x: 430, y: 715))
  flask.line(to: NSPoint(x: 430, y: 565))
  flask.line(to: NSPoint(x: 290, y: 355))
  flask.curve(to: NSPoint(x: 360, y: 265), controlPoint1: NSPoint(x: 270, y: 305), controlPoint2: NSPoint(x: 320, y: 265))
  flask.line(to: NSPoint(x: 664, y: 265))
  flask.curve(to: NSPoint(x: 734, y: 355), controlPoint1: NSPoint(x: 704, y: 265), controlPoint2: NSPoint(x: 754, y: 305))
  flask.line(to: NSPoint(x: 594, y: 565))
  flask.line(to: NSPoint(x: 594, y: 715))
  flask.close()

  // Translucent glass with a solid liquid level below y = 395.
  NSColor.white.withAlphaComponent(0.45).setFill()
  flask.fill()
  NSGraphicsContext.saveGraphicsState()
  flask.addClip()
  NSColor.white.setFill()
  NSRect(x: 0, y: 0, width: 1024, height: 395).fill()
  NSGraphicsContext.restoreGraphicsState()

  // Lip at the top of the neck.
  NSBezierPath(roundedRect: NSRect(x: 398, y: 715, width: 228, height: 44), xRadius: 22, yRadius: 22).fill()
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
  fputs("usage: build-icons.swift <output-directory>\n", stderr)
  exit(2)
}
let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
let icons: [(name: String, design: (CGFloat) -> Void)] = [
  ("Relay", drawRelay),
  ("Repro", drawRepro),
]

for icon in icons {
  let iconset = outputDirectory.appendingPathComponent("\(icon.name).iconset", isDirectory: true)
  try? FileManager.default.removeItem(at: iconset)
  try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
  for entry in iconsetEntries {
    let png = try renderPNG(pixels: entry.pixels, design: icon.design)
    try png.write(to: iconset.appendingPathComponent("\(entry.name).png"))
  }
  print("Rendered \(iconset.path)")
}
