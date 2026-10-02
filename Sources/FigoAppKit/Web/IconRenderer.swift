import AppKit
import UniformTypeIdentifiers

/// Renders Finder icons as PNG for `fig://icon` and `fig://path`. The page draws every named and
/// brand icon itself; only system file-type and file-path icons come from here.
public enum IconRenderer {
  public static let pixelSize = 64

  public static func png(for request: IconRequest) -> Data? {
    render(image(for: request))
  }

  static func image(for request: IconRequest) -> NSImage {
    let workspace = NSWorkspace.shared
    switch request {
    case .fileType(let type):
      return workspace.icon(for: contentType(forFileType: type))
    case .path(let path):
      var isDirectory: ObjCBool = false
      if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
        return workspace.icon(forFile: path)
      }
      if path.hasSuffix("/") { return workspace.icon(for: .folder) }
      let pathExtension = (path as NSString).pathExtension
      return workspace.icon(for: pathExtension.isEmpty ? .data : contentType(forFileType: pathExtension))
    }
  }

  /// A file extension (`ts`), a type identifier (`public.folder`) or one of a few plain words.
  static func contentType(forFileType type: String) -> UTType {
    switch type.lowercased() {
    case "folder", "directory": return .folder
    case "file": return .data
    case "symlink", "alias": return .symbolicLink
    case "application", "app": return .applicationBundle
    default: break
    }
    if let byExtension = UTType(filenameExtension: type), byExtension.isDeclared { return byExtension }
    if type.contains("."), let byIdentifier = UTType(type) { return byIdentifier }
    return .data
  }

  static func render(_ image: NSImage) -> Data? {
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixelSize, pixelsHigh: pixelSize, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let rect = NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
    image.draw(in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])
  }
}
