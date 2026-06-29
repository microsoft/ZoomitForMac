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