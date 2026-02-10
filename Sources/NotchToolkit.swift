import Cocoa

// MARK: - Tool Protocol

protocol NotchTool {
    var name: String { get }
    var description: String { get }
    var inputSchema: [String: Any] { get }

    func execute(input: [String: Any], completion: @escaping (ToolResult) -> Void)
}

enum ToolResult {
    case text(String)
    case image(data: Data, mediaType: String)
    case error(String)
}

// MARK: - Screenshot Tool

class ScreenshotTool: NotchTool {
    let name = "screenshot"
    let description = "See their screen. What they're looking at, working on, stuck on."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [:],
        "required": []
    ]

    func execute(input: [String: Any], completion: @escaping (ToolResult) -> Void) {
        guard let screenShot = CGWindowListCreateImage(
            CGRect.infinite,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution]
        ) else {
            completion(.error("Failed to capture screenshot"))
            return
        }

        let originalImage = NSImage(cgImage: screenShot, size: NSSize(
            width: CGFloat(screenShot.width),
            height: CGFloat(screenShot.height)
        ))

        let scaledSize = NSSize(
            width: originalImage.size.width / 2,
            height: originalImage.size.height / 2
        )

        let scaledImage = NSImage(size: scaledSize)
        scaledImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        originalImage.draw(
            in: NSRect(origin: .zero, size: scaledSize),
            from: NSRect(origin: .zero, size: originalImage.size),
            operation: .copy,
            fraction: 1.0
        )
        scaledImage.unlockFocus()

        guard let tiffData = scaledImage.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmapRep.representation(
                  using: .jpeg,
                  properties: [.compressionFactor: 0.6]
              ) else {
            completion(.error("Failed to compress screenshot"))
            return
        }

        completion(.image(data: jpegData, mediaType: "image/jpeg"))
    }
}
