// Draws Figo's app icon and writes Resources/AppIcon.icns.
//
//   swift scripts/make-icon.swift
//
// The icon is a prompt chevron with a small suggestion list beside it. It is generated rather
// than drawn by hand so it can be tweaked in code; the .icns output is committed.
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(getpid()).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(size: Int) -> Data {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  let s = CGFloat(size)
  // macOS icon grid: the tile is inset ~10% with a continuous-looking corner radius.
  let tile = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
  let tilePath = NSBezierPath(roundedRect: tile, xRadius: s * 0.18, yRadius: s * 0.18)
  NSGradient(
    starting: NSColor(srgbRed: 0.09, green: 0.16, blue: 0.27, alpha: 1),
    ending: NSColor(srgbRed: 0.05, green: 0.36, blue: 0.42, alpha: 1))!.draw(in: tilePath, angle: -60)

  // Prompt chevron.
  let chevron = NSBezierPath()
  chevron.move(to: NSPoint(x: s * 0.24, y: s * 0.63))
  chevron.line(to: NSPoint(x: s * 0.36, y: s * 0.53))
  chevron.line(to: NSPoint(x: s * 0.24, y: s * 0.43))
  chevron.lineWidth = s * 0.05
  chevron.lineCapStyle = .round
  chevron.lineJoinStyle = .round
  NSColor.white.setStroke()
  chevron.stroke()

  // Suggestion list: a selected row and two plain ones.
  let rows: [(CGFloat, NSColor)] = [
    (0.58, NSColor(srgbRed: 0.27, green: 0.55, blue: 1, alpha: 1)),
    (0.46, NSColor(white: 1, alpha: 0.55)),
    (0.34, NSColor(white: 1, alpha: 0.35)),
  ]
  for (y, color) in rows {
    color.setFill()
    NSBezierPath(
      roundedRect: NSRect(x: s * 0.44, y: s * y, width: s * 0.34, height: s * 0.08), xRadius: s * 0.025,
      yRadius: s * 0.025
    ).fill()
  }
  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
  try draw(size: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
  try draw(size: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let output = root.appendingPathComponent("Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(output.path)")
