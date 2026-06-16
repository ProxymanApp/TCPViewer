//
//  generate-app-icons.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 15/6/26.
//

import AppKit
import Foundation

private struct AppIconSlot {
    let filename: String
    let pixels: Int
}

private let repositoryRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
private let appIconSetURL = repositoryRoot.appendingPathComponent("TCPViewer/Assets.xcassets/AppIcon.appiconset")
private let appIconDocumentURL = repositoryRoot.appendingPathComponent("TCPViewer/AppIcon.icon")
private let appIconAssetsURL = appIconDocumentURL.appendingPathComponent("Assets")
private let lightMasterURL = appIconAssetsURL.appendingPathComponent("light.png")
private let darkMasterURL = appIconAssetsURL.appendingPathComponent("dark.png")
private let legacyMasterURL = appIconSetURL.appendingPathComponent("AppIcon-512@2x.png")

private let appIconSlots = [
    AppIconSlot(filename: "AppIcon-16.png", pixels: 16),
    AppIconSlot(filename: "AppIcon-16@2x.png", pixels: 32),
    AppIconSlot(filename: "AppIcon-32.png", pixels: 32),
    AppIconSlot(filename: "AppIcon-32@2x.png", pixels: 64),
    AppIconSlot(filename: "AppIcon-128.png", pixels: 128),
    AppIconSlot(filename: "AppIcon-128@2x.png", pixels: 256),
    AppIconSlot(filename: "AppIcon-256.png", pixels: 256),
    AppIconSlot(filename: "AppIcon-256@2x.png", pixels: 512),
    AppIconSlot(filename: "AppIcon-512.png", pixels: 512),
    AppIconSlot(filename: "AppIcon-512@2x.png", pixels: 1024)
]

private enum GeneratorError: Error, CustomStringConvertible {
    case missingSource(URL)
    case imageLoadFailed(URL)
    case unsupportedBitmap(URL)
    case ictoolUnavailable
    case processFailed(executable: String, arguments: [String], status: Int32, output: String)

    var description: String {
        switch self {
        case .missingSource(let url):
            return "Missing app icon source at \(url.path)."
        case .imageLoadFailed(let url):
            return "Failed to load image at \(url.path)."
        case .unsupportedBitmap(let url):
            return "Failed to create an RGBA bitmap for \(url.path)."
        case .ictoolUnavailable:
            return "Could not find Xcode's ictool. Install Xcode 26 or later."
        case .processFailed(let executable, let arguments, let status, let output):
            let command = ([executable] + arguments).joined(separator: " ")
            return "Command failed with exit code \(status): \(command)\n\(output)"
        }
    }
}

private struct RGBColor {
    let red: Double
    let green: Double
    let blue: Double
}

private struct RGBAImage {
    let width: Int
    let height: Int
    var pixels: [UInt8]
}

private func run() throws {
    let sourceURL = try iconSourceURL()
    let sourceImage = try loadRGBAImage(from: sourceURL)
    let darkImage = makeDarkIconImage(from: sourceImage)

    try FileManager.default.createDirectory(at: appIconAssetsURL, withIntermediateDirectories: true)
    try writePNG(sourceImage, to: lightMasterURL)
    try writePNG(darkImage, to: darkMasterURL)
    try writeIconComposerManifest()

    let ictoolURL = try findICTool()
    for slot in appIconSlots {
        try renderIcon(
            using: ictoolURL,
            rendition: "Default",
            pixels: slot.pixels,
            outputURL: appIconSetURL.appendingPathComponent(slot.filename)
        )
    }

    try renderIcon(
        using: ictoolURL,
        rendition: "Dark",
        pixels: 1024,
        outputURL: appIconDocumentURL.appendingPathComponent("dark-preview.png")
    )
    try FileManager.default.removeItem(at: appIconDocumentURL.appendingPathComponent("dark-preview.png"))

    print("Generated AppIcon.icon and \(appIconSlots.count) fallback app icon PNGs.")
}

// Use the preserved Icon Composer light asset after the first run so regeneration is idempotent.
private func iconSourceURL() throws -> URL {
    if FileManager.default.fileExists(atPath: lightMasterURL.path) {
        return lightMasterURL
    }
    guard FileManager.default.fileExists(atPath: legacyMasterURL.path) else {
        throw GeneratorError.missingSource(legacyMasterURL)
    }
    return legacyMasterURL
}

private func loadRGBAImage(from url: URL) throws -> RGBAImage {
    guard let image = NSImage(contentsOf: url),
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        throw GeneratorError.imageLoadFailed(url)
    }

    let width = cgImage.width
    let height = cgImage.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw GeneratorError.unsupportedBitmap(url)
    }

    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    return RGBAImage(width: width, height: height, pixels: pixels)
}

private func writePNG(_ image: RGBAImage, to url: URL) throws {
    var pixels = image.pixels
    guard let context = CGContext(
        data: &pixels,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: image.width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ), let cgImage = context.makeImage() else {
        throw GeneratorError.unsupportedBitmap(url)
    }

    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw GeneratorError.unsupportedBitmap(url)
    }
    try data.write(to: url, options: .atomic)
}

// Flood-fill from the image edges so only the connected cream/white tile is recolored.
private func makeDarkIconImage(from image: RGBAImage) -> RGBAImage {
    var result = image
    let pixelCount = image.width * image.height
    var isBackground = [Bool](repeating: false, count: pixelCount)

    for index in 0..<pixelCount where isBackgroundCandidate(at: index, in: image) {
        isBackground[index] = true
    }

    var visited = [Bool](repeating: false, count: pixelCount)
    var queue = [Int]()
    queue.reserveCapacity(pixelCount / 2)

    func enqueueIfBackground(_ x: Int, _ y: Int) {
        guard x >= 0, x < image.width, y >= 0, y < image.height else { return }
        let index = y * image.width + x
        guard isBackground[index], !visited[index] else { return }
        visited[index] = true
        queue.append(index)
    }

    for x in 0..<image.width {
        enqueueIfBackground(x, 0)
        enqueueIfBackground(x, image.height - 1)
    }
    for y in 0..<image.height {
        enqueueIfBackground(0, y)
        enqueueIfBackground(image.width - 1, y)
    }

    var head = 0
    while head < queue.count {
        let index = queue[head]
        head += 1

        let x = index % image.width
        let y = index / image.width
        enqueueIfBackground(x - 1, y)
        enqueueIfBackground(x + 1, y)
        enqueueIfBackground(x, y - 1)
        enqueueIfBackground(x, y + 1)
    }

    var backgroundMask = visited
    expandBackgroundMask(&backgroundMask, in: image, iterations: 1)

    for index in 0..<pixelCount where backgroundMask[index] {
        recolorBackgroundPixel(at: index, in: &result)
    }

    removeLightMatte(from: &result, using: backgroundMask)

    return result
}

private func isBackgroundCandidate(at index: Int, in image: RGBAImage) -> Bool {
    let offset = index * 4
    let red = Double(image.pixels[offset]) / 255.0
    let green = Double(image.pixels[offset + 1]) / 255.0
    let blue = Double(image.pixels[offset + 2]) / 255.0
    let alpha = Double(image.pixels[offset + 3]) / 255.0
    let maxChannel = max(red, green, blue)
    let minChannel = min(red, green, blue)
    let saturation = maxChannel == 0 ? 0 : (maxChannel - minChannel) / maxChannel
    let warmth = red - blue

    let warmCream = maxChannel > 0.58 && saturation < 0.18 && warmth > 0.015
    let whiteCorner = maxChannel > 0.88 && saturation < 0.08
    return alpha > 0.9 && (warmCream || whiteCorner)
}

private func expandBackgroundMask(_ mask: inout [Bool], in image: RGBAImage, iterations: Int) {
    for _ in 0..<iterations {
        var expandedMask = mask

        for index in mask.indices where !mask[index] {
            guard isMatteEdgeCandidate(at: index, in: image) else { continue }
            if hasMaskedNeighbor(at: index, in: mask, width: image.width, height: image.height) {
                expandedMask[index] = true
            }
        }

        mask = expandedMask
    }
}

private func isMatteEdgeCandidate(at index: Int, in image: RGBAImage) -> Bool {
    let offset = index * 4
    let red = Double(image.pixels[offset]) / 255.0
    let green = Double(image.pixels[offset + 1]) / 255.0
    let blue = Double(image.pixels[offset + 2]) / 255.0
    let alpha = Double(image.pixels[offset + 3]) / 255.0
    let maxChannel = max(red, green, blue)
    let minChannel = min(red, green, blue)
    let saturation = maxChannel == 0 ? 0 : (maxChannel - minChannel) / maxChannel
    let warmth = red - blue

    let brightNeutral = maxChannel > 0.50 && saturation < 0.24
    let paleWarm = maxChannel > 0.42 && saturation < 0.32 && warmth > -0.03
    return alpha > 0.9 && (brightNeutral || paleWarm)
}

private func hasMaskedNeighbor(at index: Int, in mask: [Bool], width: Int, height: Int) -> Bool {
    let x = index % width
    let y = index / width

    for dy in -1...1 {
        for dx in -1...1 where dx != 0 || dy != 0 {
            let neighborX = x + dx
            let neighborY = y + dy
            guard neighborX >= 0, neighborX < width, neighborY >= 0, neighborY < height else { continue }
            if mask[neighborY * width + neighborX] {
                return true
            }
        }
    }

    return false
}

// The source art is flattened on a cream background, so edge pixels contain a light matte.
private func removeLightMatte(from image: inout RGBAImage, using backgroundMask: [Bool]) {
    let originalPixels = image.pixels

    for index in backgroundMask.indices where !backgroundMask[index] {
        let neighborCount = maskedNeighborCount(around: index, in: backgroundMask, width: image.width, height: image.height)
        guard neighborCount > 0 else { continue }
        guard isLightFringePixel(at: index, in: originalPixels) else { continue }

        let x = index % image.width
        let y = index / image.width
        let color = darkBackgroundColor(x: x, y: y, width: image.width, height: image.height)
        let amount = min(0.55, 0.18 + Double(neighborCount) * 0.055)
        blendPixel(at: index, in: &image, toward: color, amount: amount)
    }
}

private func maskedNeighborCount(around index: Int, in mask: [Bool], width: Int, height: Int) -> Int {
    let x = index % width
    let y = index / width
    var count = 0

    for dy in -2...2 {
        for dx in -2...2 where dx != 0 || dy != 0 {
            let neighborX = x + dx
            let neighborY = y + dy
            guard neighborX >= 0, neighborX < width, neighborY >= 0, neighborY < height else { continue }
            if mask[neighborY * width + neighborX] {
                count += 1
            }
        }
    }

    return count
}

private func isLightFringePixel(at index: Int, in pixels: [UInt8]) -> Bool {
    let offset = index * 4
    let red = Double(pixels[offset]) / 255.0
    let green = Double(pixels[offset + 1]) / 255.0
    let blue = Double(pixels[offset + 2]) / 255.0
    let maxChannel = max(red, green, blue)
    let minChannel = min(red, green, blue)
    let saturation = maxChannel == 0 ? 0 : (maxChannel - minChannel) / maxChannel

    return maxChannel > 0.62 && saturation < 0.28
}

private func recolorBackgroundPixel(at index: Int, in image: inout RGBAImage) {
    let x = index % image.width
    let y = index / image.width
    let offset = index * 4
    let color = darkBackgroundColor(x: x, y: y, width: image.width, height: image.height)

    image.pixels[offset] = UInt8(clamping: Int(color.red))
    image.pixels[offset + 1] = UInt8(clamping: Int(color.green))
    image.pixels[offset + 2] = UInt8(clamping: Int(color.blue))
    image.pixels[offset + 3] = 255
}

private func darkBackgroundColor(x: Int, y: Int, width: Int, height: Int) -> RGBColor {
    let vertical = Double(y) / Double(max(1, height - 1))
    let horizontal = Double(x) / Double(max(1, width - 1))
    let radial = distanceFromCenter(x: horizontal, y: vertical)

    let top = (red: 54.0, green: 72.0, blue: 78.0)
    let bottom = (red: 12.0, green: 24.0, blue: 29.0)
    let glow = max(0, 1 - radial * 1.55) * 18

    return RGBColor(
        red: top.red * (1 - vertical) + bottom.red * vertical + glow,
        green: top.green * (1 - vertical) + bottom.green * vertical + glow,
        blue: top.blue * (1 - vertical) + bottom.blue * vertical + glow
    )
}

private func blendPixel(at index: Int, in image: inout RGBAImage, toward color: RGBColor, amount: Double) {
    let offset = index * 4
    let inverseAmount = 1 - amount

    image.pixels[offset] = UInt8(clamping: Int(Double(image.pixels[offset]) * inverseAmount + color.red * amount))
    image.pixels[offset + 1] = UInt8(clamping: Int(Double(image.pixels[offset + 1]) * inverseAmount + color.green * amount))
    image.pixels[offset + 2] = UInt8(clamping: Int(Double(image.pixels[offset + 2]) * inverseAmount + color.blue * amount))
}

private func distanceFromCenter(x: Double, y: Double) -> Double {
    let dx = x - 0.5
    let dy = y - 0.42
    return sqrt(dx * dx + dy * dy)
}

private func writeIconComposerManifest() throws {
    let manifest = """
    {
      "fill" : "system-light",
      "groups" : [
        {
          "layers" : [
            {
              "glass" : false,
              "hidden" : false,
              "image-name-specializations" : [
                {
                  "value" : "light.png"
                },
                {
                  "appearance" : "dark",
                  "value" : "dark.png"
                }
              ],
              "name" : "TCP Viewer Icon",
              "position" : {
                "scale" : 1,
                "translation-in-points" : [
                  0,
                  0
                ]
              }
            }
          ],
          "shadow" : {
            "kind" : "neutral",
            "opacity" : 0
          },
          "specular" : false,
          "translucency" : {
            "enabled" : false,
            "value" : 0
          }
        }
      ],
      "supported-platforms" : {
        "squares" : "shared"
      }
    }

    """

    try manifest.write(
        to: appIconDocumentURL.appendingPathComponent("icon.json"),
        atomically: true,
        encoding: .utf8
    )
}

private func findICTool() throws -> URL {
    let candidates = [
        "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool",
        "/Applications/Xcode.app/Contents/Developer/usr/bin/ictool"
    ]

    for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
        return URL(fileURLWithPath: candidate)
    }
    throw GeneratorError.ictoolUnavailable
}

private func renderIcon(using ictoolURL: URL, rendition: String, pixels: Int, outputURL: URL) throws {
    let arguments = [
        appIconDocumentURL.path,
        "--export-image",
        "--output-file",
        outputURL.path,
        "--platform",
        "macOS",
        "--rendition",
        rendition,
        "--width",
        String(pixels),
        "--height",
        String(pixels),
        "--scale",
        "1"
    ]

    try runProcess(executable: ictoolURL.path, arguments: arguments)
    let normalizedImage = try loadRGBAImage(from: outputURL)
    try writePNG(normalizedImage, to: outputURL)
}

private func runProcess(executable: String, arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    try process.run()
    process.waitUntilExit()

    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
        throw GeneratorError.processFailed(
            executable: executable,
            arguments: arguments,
            status: process.terminationStatus,
            output: output
        )
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
