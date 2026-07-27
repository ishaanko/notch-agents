#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Foundation

private let canvasCells = 10
private let pixelsPerCell = 4
private let pixelSize = canvasCells * pixelsPerCell

private struct ActivityStateArtwork {
    let filename: String
    let rows: [String]
}

private let artwork: [ActivityStateArtwork] = [
    .init(
        filename: "thinking.png",
        rows: [
            "..........",
            "...+##+...",
            ".+#....#+.",
            "..#.+..#..",
            "+..##...#+",
            ".#....+#..",
            "..#+..#...",
            ".+.##..+..",
            "...+......",
            "..........",
        ]
    ),
    .init(
        filename: "tool.png",
        rows: [
            "..........",
            "..+....+..",
            ".#..##..#.",
            "...####...",
            "+.######.+",
            "...####...",
            ".#..##..#.",
            "..+....+..",
            "....+.....",
            "..........",
        ]
    ),
    .init(
        filename: "editing.png",
        rows: [
            "..........",
            "......+#..",
            "....+#....",
            "...#...+..",
            ".+#..+#...",
            "#..+#.....",
            ".+#....#..",
            "...+#...+.",
            ".....+#...",
            "..........",
        ]
    ),
    .init(
        filename: "waiting.png",
        rows: [
            "..........",
            "...+..+...",
            "..#....#..",
            ".#..++..#.",
            "+..#..#..+",
            "+..#..#..+",
            ".#..++..#.",
            "..#....#..",
            "...+..+...",
            "..........",
        ]
    ),
    .init(
        filename: "question.png",
        rows: [
            "..........",
            "....+.....",
            "..+...+...",
            ".#..+..#..",
            "+..#.#..+.",
            ".#..+..#..",
            "..+...+...",
            "....+.....",
            "..........",
            "..........",
        ]
    ),
    .init(
        filename: "approval.png",
        rows: [
            "..........",
            "...+##+...",
            "..######..",
            ".##+##+##.",
            "+########+",
            "+########+",
            ".##+##+##.",
            "..######..",
            "...+##+...",
            "..........",
        ]
    ),
    .init(
        filename: "success.png",
        rows: [
            "..........",
            "....+.....",
            ".+..#..+..",
            "..#.+.#...",
            "+..###..+.",
            ".+.###.+..",
            "..#.+.#...",
            ".+..#..+..",
            "....+.....",
            "..........",
        ]
    ),
    .init(
        filename: "failure.png",
        rows: [
            "..........",
            ".+......+.",
            "...#..#...",
            ".#..++..#.",
            "....##....",
            "....##....",
            ".#..++..#.",
            "...#..#...",
            ".+......+.",
            "..........",
        ]
    ),
]

private func makePNG(for state: ActivityStateArtwork) throws -> Data {
    precondition(state.rows.count == canvasCells)
    precondition(state.rows.allSatisfy { $0.count == canvasCells })

    guard
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize,
            pixelsHigh: pixelSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: pixelSize * 4,
            bitsPerPixel: 32
        ),
        let bitmapData = bitmap.bitmapData,
        let context = CGContext(
            data: bitmapData,
            width: pixelSize,
            height: pixelSize,
            bitsPerComponent: 8,
            bytesPerRow: bitmap.bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else {
        throw NSError(
            domain: "ActivityStateIconGenerator",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not create a bitmap context."]
        )
    }

    context.clear(CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)

    for (rowIndex, row) in state.rows.enumerated() {
        for (columnIndex, cell) in row.enumerated() where cell == "#" || cell == "+" {
            let x = columnIndex * pixelsPerCell
            let y = (canvasCells - rowIndex - 1) * pixelsPerCell
            context.setFillColor(
                NSColor.white.withAlphaComponent(cell == "#" ? 1 : 0.42).cgColor
            )
            let dotRect = CGRect(
                x: CGFloat(x) + 0.5,
                y: CGFloat(y) + 0.5,
                width: CGFloat(pixelsPerCell - 1),
                height: CGFloat(pixelsPerCell - 1)
            )
            context.fillEllipse(in: dotRect)
        }
    }

    bitmap.size = NSSize(width: pixelSize / 2, height: pixelSize / 2)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(
            domain: "ActivityStateIconGenerator",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Could not encode \(state.filename)."]
        )
    }
    return data
}

let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let defaultOutput = projectRoot
    .appendingPathComponent("Sources")
    .appendingPathComponent("NotchAgents")
    .appendingPathComponent("Resources")
    .appendingPathComponent("ActivityStates")
let outputDirectory = CommandLine.arguments.dropFirst().first
    .map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? defaultOutput

try FileManager.default.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
)

for state in artwork {
    let destination = outputDirectory.appendingPathComponent(state.filename)
    try makePNG(for: state).write(to: destination, options: .atomic)
    print(destination.path)
}
