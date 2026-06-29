import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ZoomItMacCore

// Offline panorama stitch: `ZoomItMacSelfTest --stitch <dumpDir> <out.png>`
// Reads width,height-prefixed RGBA frame_*.bin dumps (ZOOMIT_PANORAMA_DUMP) and
// stitches them, so real captures can be debugged without the live app.
let args = CommandLine.arguments
if args.count >= 4, args[1] == "--frame" {
    let dir = URL(fileURLWithPath: args[2], isDirectory: true)
    let idx = Int(args[3]) ?? 0
    let f = dir.appendingPathComponent(String(format: "frame_%04d.bin", idx))
    if let data = try? Data(contentsOf: f), let nl = data.firstIndex(of: 0x0A) {
        let parts = String(decoding: data[..<nl], as: UTF8.self).split(separator: " ")
        let w = Int(parts[0])!, h = Int(parts[1])!
        var px = Array(data[(nl + 1)...])
        let cs = CGColorSpaceCreateDeviceRGB()
        px.withUnsafeMutableBytes { p in
            let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let img = ctx.makeImage()!
            let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "/tmp/frame.png") as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(dst, img, nil); CGImageDestinationFinalize(dst)
        }
        print("wrote /tmp/frame.png \(w)x\(h)")
    }
    Foundation.exit(EXIT_SUCCESS)
}
if args.count >= 4, args[1] == "--stitch" {
    let dir = URL(fileURLWithPath: args[2], isDirectory: true)
    let out = URL(fileURLWithPath: args[3])
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
        .filter { $0.lastPathComponent.hasPrefix("frame_") }.sorted { $0.path < $1.path } ?? []
    var frames: [PanoramaStitcher.Frame] = []
    for f in files {
        guard let data = try? Data(contentsOf: f), let nl = data.firstIndex(of: 0x0A) else { continue }
        let parts = String(decoding: data[..<nl], as: UTF8.self).split(separator: " ")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { continue }
        frames.append(.init(width: w, height: h, pixels: Array(data[(nl + 1)...])))
    }
    print("Loaded \(frames.count) frames")
    if let s = PanoramaStitcher.stitch(frames: frames) {
        print("Stitched \(s.width)x\(s.height)")
        let cs = CGColorSpaceCreateDeviceRGB()
        var pix = s.pixels
        pix.withUnsafeMutableBytes { p in
            let ctx = CGContext(data: p.baseAddress, width: s.width, height: s.height, bitsPerComponent: 8,
                                bytesPerRow: s.width * 4, space: cs,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            if let img = ctx.makeImage() {
                let dst = CGImageDestinationCreateWithURL(out as CFURL, "public.png" as CFString, 1, nil)!
                CGImageDestinationAddImage(dst, img, nil); CGImageDestinationFinalize(dst)
            }
        }
        print("Wrote \(out.path)")
    }
    Foundation.exit(EXIT_SUCCESS)
}

if args.count >= 3, args[1] == "--shifts" {
    let dir = URL(fileURLWithPath: args[2], isDirectory: true)
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
        .filter { $0.lastPathComponent.hasPrefix("frame_") }.sorted { $0.path < $1.path } ?? []
    var frames: [PanoramaStitcher.Frame] = []
    for f in files {
        guard let data = try? Data(contentsOf: f), let nl = data.firstIndex(of: 0x0A) else { continue }
        let parts = String(decoding: data[..<nl], as: UTF8.self).split(separator: " ")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { continue }
        frames.append(.init(width: w, height: h, pixels: Array(data[(nl + 1)...])))
    }
    for i in 1..<frames.count {
        let pl = PanoramaStitcher.luma(frames[i-1]), cl = PanoramaStitcher.luma(frames[i])
        let w = frames[i].width, h = frames[i].height
        var best = 0, bestScore = Int.max
        for dy in 0...(h - 40) {
            var tot = 0, n = 0
            var y = 40
            while y < h - dy { let a = (y+dy)*w, b = y*w; var x = 20; while x < w-20 { tot += abs(Int(cl[b+x]) - Int(pl[a+x])); n += 1; x += 7 }; y += 5 }
            if n > 1000 { let s = tot / n; if s < bestScore { bestScore = s; best = dy } }
        }
        print("pair \(i-1)->\(i): trueDy=\(best) score=\(bestScore)")
    }
    Foundation.exit(EXIT_SUCCESS)
}

if args.count >= 2, args[1] == "--bench-stitch" {
    let width = args.count > 2 ? (Int(args[2]) ?? 1200) : 1200
    let frameHeight = args.count > 3 ? (Int(args[3]) ?? 900) : 900
    let frameCount = args.count > 4 ? (Int(args[4]) ?? 80) : 80
    let scrollPerFrame = args.count > 5 ? (Int(args[5]) ?? 90) : 90
    let iterations = args.count > 6 ? (Int(args[6]) ?? 1) : 1
    let documentHeight = frameHeight + scrollPerFrame * max(0, frameCount - 1)

    func documentPixel(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
        var hash = UInt32(x / 3) &* 747_796_405 &+ UInt32(y) &* 2_891_336_453 &+ 97
        hash = ((hash >> ((hash >> 28) + 4)) ^ hash) &* 277_803_737
        hash = (hash >> 22) ^ hash
        let textLine = y % 23 < 4 || (x + y * 5) % 61 < 7
        let block = (x / 180 + y / 120).isMultiple(of: 3)
        let boost = textLine ? 80 : (block ? 24 : 0)
        return (
            UInt8(clamping: 30 + Int((hash >> 16) & 0x7F) / 2 + boost),
            UInt8(clamping: 36 + Int((hash >> 8) & 0x7F) / 2 + boost),
            UInt8(clamping: 42 + Int(hash & 0x7F) / 2 + boost)
        )
    }

    func makeFrame(topRow: Int) -> PanoramaStitcher.Frame {
        var pixels = [UInt8](repeating: 0, count: width * frameHeight * 4)
        for y in 0..<frameHeight {
            let docY = topRow + y
            for x in 0..<width {
                let pixel = documentPixel(x: x, y: docY)
                let i = (y * width + x) * 4
                pixels[i] = pixel.0
                pixels[i + 1] = pixel.1
                pixels[i + 2] = pixel.2
                pixels[i + 3] = 255
            }
        }
        return PanoramaStitcher.Frame(width: width, height: frameHeight, pixels: pixels)
    }

    let frames = (0..<frameCount).map { makeFrame(topRow: $0 * scrollPerFrame) }
    print("Bench stitch frames=\(frameCount) frame=\(width)x\(frameHeight) step=\(scrollPerFrame) docHeight=\(documentHeight) iterations=\(iterations)")
    let start = DispatchTime.now().uptimeNanoseconds
    var stitchedSize = "nil"
    for _ in 0..<max(1, iterations) {
        if let stitched = PanoramaStitcher.stitch(frames: frames) {
            stitchedSize = "\(stitched.width)x\(stitched.height)"
        } else {
            stitchedSize = "nil"
        }
    }
    let end = DispatchTime.now().uptimeNanoseconds
    let elapsedMs = Double(end - start) / 1_000_000
    print(String(format: "Bench stitched=%@ elapsedMs=%.1f avgMs=%.1f", stitchedSize, elapsedMs, elapsedMs / Double(max(1, iterations))))
    Foundation.exit(EXIT_SUCCESS)
}

Task { @MainActor in
    do {
        try SelfTestRunner.run()
        print("ZoomItMacSelfTest: PASS")
        Foundation.exit(EXIT_SUCCESS)
    } catch {
        print("ZoomItMacSelfTest: FAIL - \(error)")
        Foundation.exit(EXIT_FAILURE)
    }
}

RunLoop.main.run()