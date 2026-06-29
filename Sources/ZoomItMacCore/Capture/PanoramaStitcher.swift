import Accelerate
import Foundation

/// Panorama (scrolling) screen-capture stitching.
///
/// This is a Swift port of the *design* of the Windows ZoomIt
/// `PanoramaCapture.cpp` stitcher. macOS has no native scrolling-capture API,
/// so the alignment is reproduced from the Windows algorithm:
///
/// 1. Reduce each 32-bpp frame to a single luma channel.
/// 2. Build a 1D "edge density" signal (per-row horizontal gradient sum for
///    vertical scrolling, per-column vertical gradient sum for horizontal
///    scrolling). Structural edges align far more reliably than raw pixels
///    when anti-aliasing shifts sub-pixel between frames.
/// 3. Find the best inter-frame shift with 1D Normalized Cross-Correlation
///    (`NCC1D`) over the edge-density signals on a downsampled frame (coarse),
///    then refine to full resolution with a small local SAD search.
/// 4. Track cumulative origins (with momentum windowing to avoid harmonic
///    matches on repetitive content) and compose all accepted frames onto a
///    single canvas. Fixed top overlays are detected and suppressed after the
///    first frame so a sticky header appears once instead of being inserted at
///    every scroll step, mirroring the Windows compositor.
///
/// The type is intentionally free of AppKit/ScreenCaptureKit dependencies so it
/// can run off the main actor (during stitching) and be exercised by the
/// self-test with synthetic frames.
public enum PanoramaStitcher {
    /// A single captured frame: tightly-packed 32-bpp RGBA, top-down (row 0 is
    /// the top of the screen), alpha opaque.
    public struct Frame: Sendable {
        public let width: Int
        public let height: Int
        public var pixels: [UInt8]
        public init(width: Int, height: Int, pixels: [UInt8]) {
            self.width = width; self.height = height; self.pixels = pixels
        }
    }

    /// The dominant scroll direction discovered from the first frame pair.
    enum Axis: Sendable { case vertical, horizontal }

    /// The inter-frame displacement: `cur[x, y]` matches `prev[x + dx, y + dy]`.
    struct Shift: Sendable {
        let dx: Int
        let dy: Int
        let axis: Axis
        let score: Double
    }

    // MARK: - Capture-phase helpers

    /// Mean per-channel absolute difference and the fraction of pixels that
    /// changed appreciably between two frames, sampled on a sparse grid.
    /// Mirrors `ComputeAveragePixelDifference` in the Windows source.
    static func frameDifference(_ a: Frame, _ b: Frame, sampleStep: Int = 6) -> (avgDiff: Double, changedFraction: Double) {
        guard a.width == b.width, a.height == b.height, a.width > 0, a.height > 0,
              a.pixels.count == b.pixels.count else {
            return (Double.greatestFiniteMagnitude, 1)
        }
        let w = a.width
        let h = a.height
        let stride = w * 4
        let marginX = max(4, w / 40)
        let marginY = max(4, h / 40)
        let startX = marginX, endX = w - marginX
        let startY = marginY, endY = h - marginY
        if endX <= startX || endY <= startY { return (Double.greatestFiniteMagnitude, 1) }
        let step = max(1, sampleStep)

        var totalDiff = 0
        var channelSamples = 0
        var changedPixels = 0
        var pixelSamples = 0

        a.pixels.withUnsafeBufferPointer { pa in
            b.pixels.withUnsafeBufferPointer { pb in
                var y = startY
                while y < endY {
                    let rowOffset = y * stride
                    var x = startX
                    while x < endX {
                        let i = rowOffset + x * 4
                        let d0 = abs(Int(pa[i]) - Int(pb[i]))
                        let d1 = abs(Int(pa[i + 1]) - Int(pb[i + 1]))
                        let d2 = abs(Int(pa[i + 2]) - Int(pb[i + 2]))
                        let sum = d0 + d1 + d2
                        totalDiff += sum
                        channelSamples += 3
                        pixelSamples += 1
                        if sum > 30 { changedPixels += 1 }
                        x += step
                    }
                    y += step
                }
            }
        }
        if channelSamples == 0 { return (Double.greatestFiniteMagnitude, 1) }
        return (Double(totalDiff) / Double(channelSamples),
                pixelSamples > 0 ? Double(changedPixels) / Double(pixelSamples) : 0)
    }

    /// True when `b` carries no meaningful new content versus `a` (a still
    /// frame captured while the user paused scrolling).
    static func isNearDuplicate(_ a: Frame, _ b: Frame) -> Bool {
        let diff = frameDifference(a, b)
        var duplicate = diff.avgDiff < 6.0 && diff.changedFraction < 0.005
        if duplicate, looksLikeSmallShiftNotDuplicate(a, b) {
            duplicate = false
        }
        if duplicate {
            let aLuma = luma(a)
            let bLuma = luma(b)
            let constantPair = constantContentFraction(aLuma, a.width, a.height) > 0.58 &&
                constantContentFraction(bLuma, b.width, b.height) > 0.58
            let informative = constantPair ? informativeLumaDifference(aLuma, bLuma, a.width, a.height) : (avgDiff: 0.0, count: 0)
            if informative.count > 0 && informative.avgDiff >= 8 {
                duplicate = false
            }
        }
        return duplicate
    }

    // MARK: - Signal primitives

    private static let lumaMatrixRGBA: [Int16] = [77, 150, 29, 0]

    /// Build a full-resolution luma array from RGBA pixels (Rec.601-ish
    /// integer weights, matching the Windows coefficients 77/150/29).
    public static func luma(_ frame: Frame) -> [UInt8] {
        let count = frame.width * frame.height
        var out = [UInt8](repeating: 0, count: count)
        guard count > 0 else { return out }

        let error = frame.pixels.withUnsafeBytes { srcBytes in
            out.withUnsafeMutableBytes { dstBytes in
                guard let srcBase = srcBytes.baseAddress,
                      let dstBase = dstBytes.baseAddress else {
                    return kvImageNullPointerArgument
                }
                var src = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: srcBase),
                    height: vImagePixelCount(frame.height),
                    width: vImagePixelCount(frame.width),
                    rowBytes: frame.width * 4
                )
                var dst = vImage_Buffer(
                    data: dstBase,
                    height: vImagePixelCount(frame.height),
                    width: vImagePixelCount(frame.width),
                    rowBytes: frame.width
                )
                return vImageMatrixMultiply_ARGB8888ToPlanar8(
                    &src,
                    &dst,
                    lumaMatrixRGBA,
                    256,
                    nil,
                    0,
                    vImage_Flags(kvImageNoFlags)
                )
            }
        }
        if error == kvImageNoError { return out }

        frame.pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                var p = 0
                while p < count {
                    let i = p * 4
                    let r = Int(src[i]), g = Int(src[i + 1]), b = Int(src[i + 2])
                    dst[p] = UInt8((r * 77 + g * 150 + b * 29) >> 8)
                    p += 1
                }
            }
        }
        return out
    }

    /// Nearest-neighbour downsample of a luma plane by `scale`.
    static func downsample(_ luma: [UInt8], _ w: Int, _ h: Int, _ scale: Int) -> (luma: [UInt8], width: Int, height: Int) {
        let dw = max(1, w / scale)
        let dh = max(1, h / scale)
        var out = [UInt8](repeating: 0, count: dw * dh)
        luma.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<dh {
                    let sy = min(h - 1, y * scale + scale / 2)
                    let srcRow = sy * w
                    let dstRow = y * dw
                    for x in 0..<dw {
                        let sx = min(w - 1, x * scale + scale / 2)
                        dst[dstRow + x] = src[srcRow + sx]
                    }
                }
            }
        }
        return (out, dw, dh)
    }

    /// Per-row sum of horizontal gradient magnitude (length `h`). Rows with
    /// text/edges score high; flat background rows score ~0.
    static func rowEdgeDensity(_ luma: [UInt8], _ w: Int, _ h: Int) -> [Int] {
        let marginX = max(2, w / 20)
        var density = [Int](repeating: 0, count: h)
        luma.withUnsafeBufferPointer { src in
            let end = w - marginX - 1
            for y in 0..<h {
                let row = y * w
                var sum = 0
                var x = marginX
                while x < end {
                    sum += abs(Int(src[row + x + 1]) - Int(src[row + x]))
                    x += 1
                }
                density[y] = sum
            }
        }
        return density
    }

    /// Per-column sum of vertical gradient magnitude (length `w`).
    static func colEdgeDensity(_ luma: [UInt8], _ w: Int, _ h: Int) -> [Int] {
        let marginY = max(2, h / 20)
        var density = [Int](repeating: 0, count: w)
        luma.withUnsafeBufferPointer { src in
            let end = h - marginY - 1
            for x in 0..<w {
                var sum = 0
                var y = marginY
                while y < end {
                    sum += abs(Int(src[(y + 1) * w + x]) - Int(src[y * w + x]))
                    y += 1
                }
                density[x] = sum
            }
        }
        return density
    }

    static func regionEdgeEnergy(_ luma: [UInt8], _ w: Int, _ h: Int, yRange: Range<Int>) -> Int {
        guard luma.count == w * h, w > 2, h > 2 else { return 0 }
        let startY = max(1, yRange.lowerBound)
        let endY = min(h, yRange.upperBound)
        guard endY > startY else { return 0 }
        var total = 0
        var samples = 0
        luma.withUnsafeBufferPointer { pixels in
            var y = startY
            while y < endY {
                var x = 1
                while x < w {
                    let index = y * w + x
                    let value = Int(pixels[index])
                    total += abs(value - Int(pixels[index - 1]))
                    total += abs(value - Int(pixels[index - w]))
                    samples += 1
                    x += 3
                }
                y += 3
            }
        }
        return samples > 0 ? total / samples : 0
    }

    /// Detect a stationary prefix at the top of two same-sized luma frames.
    /// Sticky headers/toolbars have very low same-row difference across frames;
    /// scrolling content below them changes. The result is used only to mask the
    /// matcher so fixed chrome does not pull the shift toward zero.
    static func stationaryTopRows(_ prev: [UInt8], _ cur: [UInt8], _ w: Int, _ h: Int) -> Int {
        guard prev.count == cur.count, w > 0, h > 0 else { return 0 }
        let maxRows = h / 4
        guard maxRows >= 8 else { return 0 }
        let margin = max(2, w / 40)
        let step = max(1, w / 80)
        var lastStationary = -1
        var gap = 0

        prev.withUnsafeBufferPointer { pp in
            cur.withUnsafeBufferPointer { pc in
                for y in 0..<maxRows {
                    var total = 0
                    var count = 0
                    let row = y * w
                    var x = margin
                    while x < w - margin {
                        total += abs(Int(pp[row + x]) - Int(pc[row + x]))
                        count += 1
                        x += step
                    }
                    let diff = count > 0 ? Double(total) / Double(count) : Double.greatestFiniteMagnitude
                    if diff <= 4 {
                        lastStationary = y
                        gap = 0
                    } else if lastStationary >= 0 && gap < 3 {
                        gap += 1
                    } else if lastStationary >= 0 || y > 8 {
                        break
                    }
                }
            }
        }

        let rows = lastStationary + 1
        let minimumHeaderRows = max(16, h / 32)
        guard rows >= minimumHeaderRows else { return 0 }
        let clampedRows = min(maxRows, rows + 3)
        let energy = regionEdgeEnergy(prev, w, h, yRange: 0..<clampedRows)
        let energyThreshold = clampedRows >= 40 ? 6 : 8
        return energy >= energyThreshold ? clampedRows : 0
    }

    /// Mirror of `stationaryTopRows` for sticky bottom toolbars/footers that
    /// stay pinned at the bottom of the region while the page scrolls.
    static func stationaryBottomRows(_ prev: [UInt8], _ cur: [UInt8], _ w: Int, _ h: Int) -> Int {
        guard prev.count == cur.count, w > 0, h > 0 else { return 0 }
        let maxRows = h / 4
        guard maxRows >= 8 else { return 0 }
        let margin = max(2, w / 40)
        let step = max(1, w / 80)
        var lastStationary = -1
        var gap = 0

        prev.withUnsafeBufferPointer { pp in
            cur.withUnsafeBufferPointer { pc in
                for r in 0..<maxRows {
                    let y = h - 1 - r
                    var total = 0
                    var count = 0
                    let row = y * w
                    var x = margin
                    while x < w - margin {
                        total += abs(Int(pp[row + x]) - Int(pc[row + x]))
                        count += 1
                        x += step
                    }
                    let diff = count > 0 ? Double(total) / Double(count) : Double.greatestFiniteMagnitude
                    if diff <= 4 {
                        lastStationary = r
                        gap = 0
                    } else if lastStationary >= 0 && gap < 3 {
                        gap += 1
                    } else if lastStationary >= 0 || r > 8 {
                        break
                    }
                }
            }
        }

        let rows = lastStationary + 1
        guard rows >= 8 else { return 0 }
        let clampedRows = min(maxRows, rows + 3)
        let energy = regionEdgeEnergy(prev, w, h, yRange: (h - clampedRows)..<h)
        let energyThreshold = clampedRows >= 40 ? 1 : 3
        return energy >= energyThreshold ? clampedRows : 0
    }
    /// This mirrors the Windows high-constant-content test used to avoid letting
    /// blank background dilute sparse text/edge movement.
    static func constantContentFraction(_ luma: [UInt8], _ w: Int, _ h: Int) -> Double {
        guard luma.count == w * h, w > 8, h > 8 else { return 0 }
        let sampleStep = 4
        let radius = 2
        var constantCount = 0
        var totalCount = 0
        luma.withUnsafeBufferPointer { pixels in
            var y = radius
            while y < h - radius {
                var x = radius
                while x < w - radius {
                    let center = Int(pixels[y * w + x])
                    var maxDeviation = 0
                    var ny = -radius
                    while ny <= radius && maxDeviation <= 3 {
                        var nx = -radius
                        while nx <= radius && maxDeviation <= 3 {
                            maxDeviation = max(maxDeviation, abs(Int(pixels[(y + ny) * w + x + nx]) - center))
                            nx += 2
                        }
                        ny += 2
                    }
                    totalCount += 1
                    if maxDeviation <= 3 { constantCount += 1 }
                    x += sampleStep
                }
                y += sampleStep
            }
        }
        return totalCount > 0 ? Double(constantCount) / Double(totalCount) : 0
    }

    /// Average luma difference at informative pixels (local edges/text), ported
    /// from Windows' `ComputeInformativePixelDifference` idea. This rescues
    /// sparse real scrolls whose full-frame average is dominated by background.
    static func informativeLumaDifference(_ prev: [UInt8], _ cur: [UInt8], _ w: Int, _ h: Int) -> (avgDiff: Double, count: Int) {
        guard prev.count == cur.count, w > 8, h > 8 else { return (0, 0) }
        let edgeThreshold = 4
        var total = 0
        var count = 0
        prev.withUnsafeBufferPointer { pp in
            cur.withUnsafeBufferPointer { pc in
                var y = 1
                while y < h - 1 {
                    var x = 1
                    while x < w - 1 {
                        let idx = y * w + x
                        let prevL = Int(pp[idx])
                        let curL = Int(pc[idx])
                        let prevGrad = abs(prevL - Int(pp[idx + 1])) + abs(prevL - Int(pp[idx + w]))
                        let curGrad = abs(curL - Int(pc[idx + 1])) + abs(curL - Int(pc[idx + w]))
                        if prevGrad >= edgeThreshold || curGrad >= edgeThreshold {
                            total += abs(curL - prevL)
                            count += 1
                        }
                        x += 2
                    }
                    y += 2
                }
            }
        }
        return count > 0 ? (Double(total) / Double(count), count) : (0, 0)
    }

    static func looksLikeSmallShiftNotDuplicate(_ a: Frame, _ b: Frame) -> Bool {
        guard a.width == b.width, a.height == b.height else { return false }
        let w = a.width
        let h = a.height
        let scale = min(w, h) >= 240 ? 4 : 2
        let prevLuma = luma(a)
        let curLuma = luma(b)
        let (prevDS, dw, dh) = downsample(prevLuma, w, h, scale)
        let (curDS, _, _) = downsample(curLuma, w, h, scale)
        guard dw >= 8, dh >= 8 else { return false }

        let maxDy = max(1, 16 / scale)
        let maxDx = max(0, 8 / scale)
        let marginX = max(2, dw / 20)
        let marginY = max(2, dh / 20)

        func score(dx: Int, dy: Int) -> Double? {
            let overlapW = dw - 2 * marginX - abs(dx)
            let overlapH = dh - 2 * marginY - abs(dy)
            if overlapW <= dw / 4 || overlapH <= dh / 4 { return nil }
            let prevX = marginX + max(0, -dx)
            let curX = marginX + max(0, dx)
            let prevY = marginY + max(0, -dy)
            let curY = marginY + max(0, dy)
            var total = 0
            var samples = 0
            var y = 0
            while y < overlapH {
                let prevRow = (prevY + y) * dw + prevX
                let curRow = (curY + y) * dw + curX
                var x = 0
                while x < overlapW {
                    total += abs(Int(prevDS[prevRow + x]) - Int(curDS[curRow + x]))
                    samples += 1
                    x += 2
                }
                y += 2
            }
            guard samples >= 200 else { return nil }
            return Double(total) / Double(samples)
        }

        guard let stationary = score(dx: 0, dy: 0), stationary >= 4 else { return false }
        var best = stationary
        var bestShift = (dx: 0, dy: 0)
        for dy in -maxDy...maxDy {
            for dx in -maxDx...maxDx where dx != 0 || dy != 0 {
                guard let candidate = score(dx: dx, dy: dy), candidate < best else { continue }
                best = candidate
                bestShift = (dx, dy)
            }
        }
        guard bestShift.dx != 0 || bestShift.dy != 0 else { return false }
        return best + 2 <= stationary && best * 100 <= stationary * 85 && best <= 25
    }

    /// 1D Normalized Cross-Correlation over `n` elements, comparing
    /// `a[aOff + k]` with `b[bOff + k]`. Returns a value in [-1, 1], or 0 if
    /// either window has zero variance. Port of `NCC1D`.
    static func ncc(_ a: [Int], _ aOff: Int, _ b: [Int], _ bOff: Int, _ n: Int) -> Double {
        if n <= 0 { return 0 }
        var sumA = 0.0, sumB = 0.0, sumAB = 0.0, sumA2 = 0.0, sumB2 = 0.0
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                var k = 0
                while k < n {
                    let av = Double(pa[aOff + k])
                    let bv = Double(pb[bOff + k])
                    sumA += av; sumB += bv
                    sumAB += av * bv
                    sumA2 += av * av; sumB2 += bv * bv
                    k += 1
                }
            }
        }
        let N = Double(n)
        let varA = sumA2 / N - (sumA / N) * (sumA / N)
        let varB = sumB2 / N - (sumB / N) * (sumB / N)
        if varA <= 0 || varB <= 0 { return 0 }
        let cov = sumAB / N - (sumA / N) * (sumB / N)
        return cov / (varA * varB).squareRoot()
    }

    /// Find the shift `s` in `[lo, hi]` that best aligns the two 1D signals,
    /// where `cur[k]` is matched against `prev[k + s]`.
    static func bestShift1D(prev: [Int], cur: [Int], lo: Int, hi: Int, minOverlap: Int, minAbsShift: Int = 0) -> (shift: Int, score: Double)? {
        let length = prev.count
        guard cur.count == length, lo <= hi else { return nil }
        var bestShift = 0
        var bestScore = -2.0
        var found = false
        var s = lo
        while s <= hi {
            if abs(s) < minAbsShift {
                s += 1
                continue
            }
            let n = length - abs(s)
            if n >= minOverlap {
                let score = s >= 0 ? ncc(cur, 0, prev, s, n) : ncc(cur, -s, prev, 0, n)
                if score > bestScore {
                    bestScore = score
                    bestShift = s
                    found = true
                }
            }
            s += 1
        }
        return found ? (bestShift, bestScore) : nil
    }

    /// Mean absolute luma difference over the overlap when `cur` is offset by
    /// `(dx, dy)` against `prev`. Returns the score and the sampled overlap.
    static func sad(prev: [UInt8], cur: [UInt8], w: Int, h: Int, dx: Int, dy: Int, step: Int, ignoreTopRows: Int = 0, ignoreBottomRows: Int = 0) -> (score: Double, overlap: Int) {
        let x0 = max(0, -dx), x1 = min(w, w - dx)
        let y0 = max(max(max(0, -dy), ignoreTopRows), ignoreTopRows - dy)
        let y1 = min(min(h - ignoreBottomRows, h - dy), h - ignoreBottomRows - dy)
        if x1 <= x0 || y1 <= y0 { return (Double.greatestFiniteMagnitude, 0) }
        var total = 0
        var count = 0
        prev.withUnsafeBufferPointer { pp in
            cur.withUnsafeBufferPointer { pc in
                var y = y0
                while y < y1 {
                    let curRow = y * w
                    let prevRow = (y + dy) * w
                    var x = x0
                    while x < x1 {
                        total += abs(Int(pc[curRow + x]) - Int(pp[prevRow + x + dx]))
                        count += 1
                        x += step
                    }
                    y += step
                }
            }
        }
        if count == 0 { return (Double.greatestFiniteMagnitude, 0) }
        return (Double(total) / Double(count), count)
    }

    static func coherentShiftSupport(prev: [UInt8], cur: [UInt8], w: Int, h: Int,
                                     dx: Int, dy: Int,
                                     ignoreTopRows: Int = 0, ignoreBottomRows: Int = 0) -> Bool {
        guard prev.count == cur.count, w > 8, h > 8, dx != 0 || dy != 0 else { return false }
        let x0 = max(1, -dx), x1 = min(w - 1, w - dx)
        let y0 = max(max(max(1, -dy), ignoreTopRows), ignoreTopRows - dy)
        let y1 = min(min(h - ignoreBottomRows - 1, h - dy), h - ignoreBottomRows - dy)
        guard x1 > x0, y1 > y0 else { return false }

        if abs(dy) >= abs(dx) {
            let rowStep = 2
            let xStep = 4
            let sampledRows = max(1, (y1 - y0 + rowStep - 1) / rowStep)
            let minSupportRows = max(8, sampledRows / 5)
            let minRowSamples = max(6, (x1 - x0) / (xStep * 40))
            var supportRows = 0

            prev.withUnsafeBufferPointer { pp in
                cur.withUnsafeBufferPointer { pc in
                    var y = y0
                    while y < y1 {
                        var sameTotal = 0
                        var shiftedTotal = 0
                        var samples = 0
                        let curRow = y * w
                        let prevSameRow = y * w
                        let prevShiftedRow = (y + dy) * w
                        var x = x0
                        while x < x1 {
                            let curValue = Int(pc[curRow + x])
                            let sameDiff = abs(curValue - Int(pp[prevSameRow + x]))
                            if sameDiff > 8 {
                                sameTotal += sameDiff
                                shiftedTotal += abs(curValue - Int(pp[prevShiftedRow + x + dx]))
                                samples += 1
                            }
                            x += xStep
                        }
                        if samples >= minRowSamples && shiftedTotal + max(10 * samples, sameTotal / 8) < sameTotal {
                            supportRows += 1
                        }
                        y += rowStep
                    }
                }
            }
            return supportRows >= minSupportRows
        }

        let colStep = 2
        let yStep = 4
        let sampledCols = max(1, (x1 - x0 + colStep - 1) / colStep)
        let minSupportCols = max(8, sampledCols / 5)
        let minColSamples = max(6, (y1 - y0) / (yStep * 40))
        var supportCols = 0

        prev.withUnsafeBufferPointer { pp in
            cur.withUnsafeBufferPointer { pc in
                var x = x0
                while x < x1 {
                    var sameTotal = 0
                    var shiftedTotal = 0
                    var samples = 0
                    var y = y0
                    while y < y1 {
                        let curIndex = y * w + x
                        let curValue = Int(pc[curIndex])
                        let sameDiff = abs(curValue - Int(pp[curIndex]))
                        if sameDiff > 8 {
                            sameTotal += sameDiff
                            shiftedTotal += abs(curValue - Int(pp[(y + dy) * w + x + dx]))
                            samples += 1
                        }
                        y += yStep
                    }
                    if samples >= minColSamples && shiftedTotal + max(10 * samples, sameTotal / 8) < sameTotal {
                        supportCols += 1
                    }
                    x += colStep
                }
            }
        }
        return supportCols >= minSupportCols
    }

    /// Full-resolution local SAD minimum around a coarse seed shift.
    static func refineWindow(prev: [UInt8], cur: [UInt8], w: Int, h: Int,
                             dxCenter: Int, dyCenter: Int, dxRadius: Int, dyRadius: Int,
                             ignoreTopRows: Int = 0, ignoreBottomRows: Int = 0) -> (dx: Int, dy: Int, score: Double) {
        var bestDx = dxCenter
        var bestDy = dyCenter
        var best = Double.greatestFiniteMagnitude
        let minOverlap = (w * max(1, h - ignoreTopRows - ignoreBottomRows)) / 10
        for dy in (dyCenter - dyRadius)...(dyCenter + dyRadius) {
            for dx in (dxCenter - dxRadius)...(dxCenter + dxRadius) {
                let result = sad(prev: prev, cur: cur, w: w, h: h, dx: dx, dy: dy, step: 2,
                                 ignoreTopRows: ignoreTopRows, ignoreBottomRows: ignoreBottomRows)
                if result.overlap < minOverlap { continue }
                if result.score < best {
                    best = result.score
                    bestDx = dx
                    bestDy = dy
                }
            }
        }
        return (bestDx, bestDy, best)
    }

    static func bestVerticalSADShift(prev: [UInt8], cur: [UInt8], w: Int, h: Int,
                                     lo: Int, hi: Int, minAbsShift: Int,
                                     ignoreTopRows: Int, ignoreBottomRows: Int) -> (dy: Int, score: Double)? {
        guard lo <= hi else { return nil }
        var bestDy = 0
        var best = Double.greatestFiniteMagnitude
        var found = false
        let sampleStep = 4
        let minOverlap = max(1, (w * max(1, h - ignoreTopRows - ignoreBottomRows)) / (10 * sampleStep * sampleStep))
        var dy = lo
        while dy <= hi {
            if abs(dy) >= minAbsShift {
                let result = sad(prev: prev, cur: cur, w: w, h: h, dx: 0, dy: dy,
                                 step: sampleStep, ignoreTopRows: ignoreTopRows, ignoreBottomRows: ignoreBottomRows)
                if result.overlap >= minOverlap && result.score < best {
                    best = result.score
                    bestDy = dy
                    found = true
                }
            }
            dy += 1
        }
        return found ? (bestDy, best) : nil
    }

    static func informativeVerticalSADShift(prev: [UInt8], cur: [UInt8], w: Int, h: Int,
                                            lo: Int, hi: Int, minAbsShift: Int,
                                            ignoreTopRows: Int, ignoreBottomRows: Int) -> (dy: Int, score: Double)? {
        guard lo <= hi else { return nil }
        let sampleStep = 2
        let minSamples = max(30, (w * max(1, h - ignoreTopRows - ignoreBottomRows)) / 240)

        func hasEdge(_ pixels: UnsafeBufferPointer<UInt8>, x: Int, y: Int) -> Bool {
            let index = y * w + x
            let value = Int(pixels[index])
            var gradient = 0
            if x + 1 < w { gradient += abs(value - Int(pixels[index + 1])) }
            if x > 0 { gradient += abs(value - Int(pixels[index - 1])) }
            if y + 1 < h { gradient += abs(value - Int(pixels[index + w])) }
            if y > 0 { gradient += abs(value - Int(pixels[index - w])) }
            return gradient >= 8
        }

        var bestDy = 0
        var best = Double.greatestFiniteMagnitude
        var found = false
        var dy = lo
        while dy <= hi {
            if abs(dy) >= minAbsShift {
                let x0 = 1
                let x1 = w - 1
                let y0 = max(max(max(1, -dy), ignoreTopRows), ignoreTopRows - dy)
                let y1 = min(min(min(h - 1, h - dy), h - ignoreBottomRows), h - ignoreBottomRows - dy)
                if x1 > x0 && y1 > y0 {
                    var total = 0
                    var samples = 0
                    prev.withUnsafeBufferPointer { pp in
                        cur.withUnsafeBufferPointer { pc in
                            var y = y0
                            while y < y1 {
                                let curRow = y * w
                                let prevRow = (y + dy) * w
                                var x = x0
                                while x < x1 {
                                    let curIndex = curRow + x
                                    let prevIndex = prevRow + x
                                    if hasEdge(pc, x: x, y: y) || hasEdge(pp, x: x, y: y + dy) {
                                        total += abs(Int(pc[curIndex]) - Int(pp[prevIndex]))
                                        samples += 1
                                    }
                                    x += sampleStep
                                }
                                y += sampleStep
                            }
                        }
                    }
                    if samples >= minSamples {
                        let score = Double(total) / Double(samples)
                        if score < best {
                            best = score
                            bestDy = dy
                            found = true
                        }
                    }
                }
            }
            dy += 1
        }
        return found ? (bestDy, best) : nil
    }

    /// Startup axis scan ported from Windows' `FindBestFrameShift`: compare
    /// pure vertical and pure horizontal shifts on informative pixels and bias
    /// ambiguous first-pair decisions to vertical. This prevents text/line
    /// autocorrelation from locking a tall vertical panorama onto the horizontal
    /// axis, which creates horizontal smearing and little vertical growth.
    static func axisScan(prev: [UInt8], cur: [UInt8], w: Int, h: Int, ignoreTopRows: Int,
                         lockedAxis: Axis? = nil, center: Int? = nil, radius: Int? = nil) -> (axis: Axis, shift: Int)? {
        guard prev.count == cur.count, w > 8, h > 8 else { return nil }
        let pixelCount = w * h
        var prevGradient = [Bool](repeating: false, count: pixelCount)
        var curGradient = [Bool](repeating: false, count: pixelCount)
        prev.withUnsafeBufferPointer { pp in
            cur.withUnsafeBufferPointer { pc in
                for y in 0..<(h - 1) {
                    let row = y * w
                    for x in 0..<(w - 1) {
                        let index = row + x
                        let lp = Int(pp[index])
                        prevGradient[index] = abs(lp - Int(pp[index + 1])) + abs(lp - Int(pp[index + w])) >= 4
                        let lc = Int(pc[index])
                        curGradient[index] = abs(lc - Int(pc[index + 1])) + abs(lc - Int(pc[index + w])) >= 4
                    }
                }
            }
        }

        // Scan most of the frame so fast scrolls (where the true shift exceeds a
        // small window) find the global minimum instead of locking a small
        // harmonic alias that stacks near-identical bands.
        let scanRange = max(8, (min(w, h) * 3) / 4)
        let margin = 4
        // Subsample more coarsely on large frames: the per-candidate MAD scan is
        // the dominant stitch cost, and a denser grid adds little discrimination
        // once thousands of pixels are sampled. The step stays 2 for frames with
        // a small dimension <= 600 px (every regression-test frame), so tested
        // behavior is unchanged; larger captures get a proportionally cheaper
        // scan (e.g. step 4 at 1200 px ~= a 4x reduction in samples/candidate).
        let sampleStep = max(2, min(w, h) / 200)
        let ignoredBottomRows = stationaryBottomRows(prev, cur, w, h)
        let fixedOverlayRows = ignoreTopRows + ignoredBottomRows
        let effectiveContentRows = max(1, h - fixedOverlayRows)

        func score(dx: Int, dy: Int, useGradientMask: Bool) -> Double? {
            let x0 = max(margin, -dx)
            let x1 = min(w - margin, w - dx)
            let y0 = max(max(max(margin, -dy), ignoreTopRows), ignoreTopRows - dy)
            let y1 = min(min(min(h - margin, h - dy), h - ignoredBottomRows), h - ignoredBottomRows - dy)
            let ySpan = y1 - y0
            if x1 - x0 < w / 4 || ySpan < h / 4 { return nil }
            if fixedOverlayRows > 0 && dy != 0 && ySpan < effectiveContentRows / 2 { return nil }
            var total = 0
            var samples = 0
            prev.withUnsafeBufferPointer { pp in
                cur.withUnsafeBufferPointer { pc in
                    prevGradient.withUnsafeBufferPointer { pg in
                        curGradient.withUnsafeBufferPointer { cg in
                            var y = y0
                            while y < y1 {
                                let curRow = y * w
                                let prevRow = (y + dy) * w
                                var x = x0
                                while x < x1 {
                                    let curIndex = curRow + x
                                    let prevIndex = prevRow + x + dx
                                    if !useGradientMask || pg[prevIndex] || cg[curIndex] {
                                        total += abs(Int(pc[curIndex]) - Int(pp[prevIndex]))
                                        samples += 1
                                    }
                                    x += sampleStep
                                }
                                y += sampleStep
                            }
                        }
                    }
                }
            }
            let minSamples = useGradientMask ? 20 : 100
            return samples >= minSamples ? Double(total) / Double(samples) : nil
        }

        func scanBounds(center: Int?, radius: Int?) -> (lo: Int, hi: Int) {
            guard let center, let radius else { return (-scanRange, scanRange) }
            return (max(-scanRange, center - radius), min(scanRange, center + radius))
        }

        func bestVertical(useGradientMask: Bool, center: Int? = nil, radius: Int? = nil) -> (shift: Int, score: Double)? {
            let bounds = scanBounds(center: center, radius: radius)
            guard bounds.lo <= bounds.hi else { return nil }
            let span = bounds.hi - bounds.lo + 1
            var scores = [Double](repeating: Double.greatestFiniteMagnitude, count: span)
            scores.withUnsafeMutableBufferPointer { buf in
                DispatchQueue.concurrentPerform(iterations: span) { i in
                    let dy = bounds.lo + i
                    if dy == 0 { return }
                    if let candidate = score(dx: 0, dy: dy, useGradientMask: useGradientMask) {
                        buf[i] = candidate
                    }
                }
            }
            var bestShift = 0
            var bestScore = Double.greatestFiniteMagnitude
            var found = false
            for i in 0..<span where scores[i] < bestScore {
                bestScore = scores[i]
                bestShift = bounds.lo + i
                found = true
            }
            return found ? (bestShift, bestScore) : nil
        }

        func bestHorizontal(useGradientMask: Bool, center: Int? = nil, radius: Int? = nil) -> (shift: Int, score: Double)? {
            let bounds = scanBounds(center: center, radius: radius)
            guard bounds.lo <= bounds.hi else { return nil }
            let span = bounds.hi - bounds.lo + 1
            var scores = [Double](repeating: Double.greatestFiniteMagnitude, count: span)
            scores.withUnsafeMutableBufferPointer { buf in
                DispatchQueue.concurrentPerform(iterations: span) { i in
                    let dx = bounds.lo + i
                    if dx == 0 { return }
                    if let candidate = score(dx: dx, dy: 0, useGradientMask: useGradientMask) {
                        buf[i] = candidate
                    }
                }
            }
            var bestShift = 0
            var bestScore = Double.greatestFiniteMagnitude
            var found = false
            for i in 0..<span where scores[i] < bestScore {
                bestScore = scores[i]
                bestShift = bounds.lo + i
                found = true
            }
            return found ? (bestShift, bestScore) : nil
        }

        // Once the axis is locked, only that direction is valid; a
        // perpendicular match is always spurious for a scrolling capture.
        if lockedAxis == .vertical {
            guard let v = bestVertical(useGradientMask: true, center: center, radius: radius) ??
                    bestVertical(useGradientMask: false, center: center, radius: radius) ??
                    bestVertical(useGradientMask: true) ??
                    bestVertical(useGradientMask: false) else { return nil }
            return (.vertical, v.shift)
        }
        if lockedAxis == .horizontal {
            guard let hh = bestHorizontal(useGradientMask: true, center: center, radius: radius) ??
                    bestHorizontal(useGradientMask: false, center: center, radius: radius) ??
                    bestHorizontal(useGradientMask: true) ??
                    bestHorizontal(useGradientMask: false) else { return nil }
            return (.horizontal, hh.shift)
        }

        let vertical = bestVertical(useGradientMask: true) ?? bestVertical(useGradientMask: false)
        let horizontal = bestHorizontal(useGradientMask: true) ?? bestHorizontal(useGradientMask: false)
        guard vertical != nil || horizontal != nil else { return nil }
        guard let vertical else { return horizontal.map { (.horizontal, $0.shift) } }
        guard let horizontal else { return (.vertical, vertical.shift) }

        var verticalWins = vertical.score <= horizontal.score
        let horizontalAdvantage = horizontal.score < vertical.score ? vertical.score - horizontal.score : 0
        let ambiguityMargin = max(8.0, vertical.score / 8.0)
        if horizontalAdvantage <= ambiguityMargin {
            verticalWins = true
        }
        if h >= w * 2 {
            let requiredAdvantage = max(16.0, vertical.score / 3.0)
            if horizontalAdvantage < requiredAdvantage {
                verticalWins = true
            }
        }
        return verticalWins ? (.vertical, vertical.shift) : (.horizontal, horizontal.shift)
    }

    // MARK: - Shift search

    private static let nccThreshold = 0.30

    // MARK: - Fixed overlay detection

    static func rowRGBDifference(_ a: Frame, _ b: Frame, yA: Int, yB: Int, sampleStep: Int = 4) -> Double {
        guard a.width == b.width, a.height == b.height,
              yA >= 0, yA < a.height, yB >= 0, yB < b.height else {
            return Double.greatestFiniteMagnitude
        }
        let w = a.width
        let margin = max(2, w / 40)
        let startX = margin
        let endX = w - margin
        guard endX > startX else { return Double.greatestFiniteMagnitude }

        var total = 0
        var count = 0
        a.pixels.withUnsafeBufferPointer { pa in
            b.pixels.withUnsafeBufferPointer { pb in
                let rowA = yA * w * 4
                let rowB = yB * w * 4
                var x = startX
                while x < endX {
                    let ia = rowA + x * 4
                    let ib = rowB + x * 4
                    total += abs(Int(pa[ia]) - Int(pb[ib]))
                    total += abs(Int(pa[ia + 1]) - Int(pb[ib + 1]))
                    total += abs(Int(pa[ia + 2]) - Int(pb[ib + 2]))
                    count += 3
                    x += max(1, sampleStep)
                }
            }
        }
        return count > 0 ? Double(total) / Double(count) : Double.greatestFiniteMagnitude
    }

    /// Detect a fixed header at the top of the captured region. For a real
    /// sticky header, `cur[y]` stays nearly identical to `prev[y]`, while the
    /// scrolled-page comparison `cur[y]` vs. `prev[y + stepY]` is clearly
    /// different. Rows are accepted only when that evidence is consistent across
    /// multiple composed transitions, then rounded up with a small tolerance so
    /// separators/shadows at the bottom of the header are suppressed too.
    static func fixedTopHeaderHeight(frames: [Frame], composedIndices: [Int], steps: [(x: Int, y: Int)], axis: Axis?, w: Int, h: Int) -> Int {
        guard axis == .vertical, composedIndices.count == steps.count, composedIndices.count >= 3 else { return 0 }
        let maxHeader = max(0, h / 4)
        guard maxHeader >= 12 else { return 0 }

        var support = [Int](repeating: 0, count: maxHeader)
        var stationary = [Int](repeating: 0, count: maxHeader)

        for k in 1..<composedIndices.count {
            let stepY = steps[k].y
            let absStepY = abs(stepY)
            guard absStepY >= max(4, h / 40), absStepY < h / 2 else { continue }
            let prev = frames[composedIndices[k - 1]]
            let cur = frames[composedIndices[k]]

            for y in 0..<maxHeader {
                let shiftedY = y + stepY
                guard shiftedY >= 0, shiftedY < h else { continue }
                let sameDiff = rowRGBDifference(cur, prev, yA: y, yB: y)
                let shiftedDiff = rowRGBDifference(cur, prev, yA: y, yB: shiftedY)
                guard sameDiff.isFinite, shiftedDiff.isFinite else { continue }
                support[y] += 1
                if sameDiff <= 8 && shiftedDiff >= max(24, sameDiff + 14) {
                    stationary[y] += 1
                }
            }
        }

        var lastHeaderRow = -1
        var toleratedGaps = 0
        let requiredSupport = 2
        for y in 0..<maxHeader {
            let rowLooksFixed = support[y] >= requiredSupport && stationary[y] * 3 >= support[y] * 2
            if rowLooksFixed {
                lastHeaderRow = y
                toleratedGaps = 0
            } else if lastHeaderRow >= 0 && toleratedGaps < 4 {
                toleratedGaps += 1
            } else if lastHeaderRow >= 0 {
                break
            } else if y > 8 {
                break
            }
        }

        let height = lastHeaderRow + 1
        return height >= 12 && height < maxHeader ? min(maxHeader, height + 4) : 0
    }

    /// Mirror of `fixedTopHeaderHeight` for a sticky footer pinned to the bottom
    /// of the captured region. Returns the number of bottom rows to suppress on
    /// every frame except the last so the footer appears once.
    static func fixedBottomFooterHeight(frames: [Frame], composedIndices: [Int], steps: [(x: Int, y: Int)], axis: Axis?, w: Int, h: Int) -> Int {
        guard axis == .vertical, composedIndices.count == steps.count, composedIndices.count >= 3 else { return 0 }
        let maxFooter = max(0, h / 4)
        guard maxFooter >= 12 else { return 0 }

        var support = [Int](repeating: 0, count: maxFooter)
        var stationary = [Int](repeating: 0, count: maxFooter)

        for k in 1..<composedIndices.count {
            let stepY = steps[k].y
            let absStepY = abs(stepY)
            guard absStepY >= max(4, h / 40), absStepY < h / 2 else { continue }
            let prev = frames[composedIndices[k - 1]]
            let cur = frames[composedIndices[k]]

            for r in 0..<maxFooter {
                let y = h - 1 - r
                let shiftedY = y - stepY
                guard shiftedY >= 0, shiftedY < h else { continue }
                let sameDiff = rowRGBDifference(cur, prev, yA: y, yB: y)
                let shiftedDiff = rowRGBDifference(cur, prev, yA: y, yB: shiftedY)
                guard sameDiff.isFinite, shiftedDiff.isFinite else { continue }
                support[r] += 1
                if sameDiff <= 8 && shiftedDiff >= max(24, sameDiff + 14) {
                    stationary[r] += 1
                }
            }
        }

        var lastFooterRow = -1
        var toleratedGaps = 0
        let requiredSupport = 2
        for r in 0..<maxFooter {
            let rowLooksFixed = support[r] >= requiredSupport && stationary[r] * 3 >= support[r] * 2
            if rowLooksFixed {
                lastFooterRow = r
                toleratedGaps = 0
            } else if lastFooterRow >= 0 && toleratedGaps < 4 {
                toleratedGaps += 1
            } else if lastFooterRow >= 0 {
                break
            } else if r > 8 {
                break
            }
        }

        let height = lastFooterRow + 1
        return height >= 12 && height < maxFooter ? min(maxFooter, height + 4) : 0
    }

    /// Determine the inter-frame shift. On the first pair (`axis == nil`) both
    /// directions are searched over the full range to discover the dominant
    /// scroll axis; afterwards the search is windowed around the expected shift
    /// (momentum) on the locked axis, falling back to a full-range search if
    /// the windowed correlation is weak (e.g. the user reversed direction).
    static func findShift(prevLuma: [UInt8], curLuma: [UInt8], w: Int, h: Int,
                          expected: (dx: Int, dy: Int)?, axis: Axis?) -> Shift? {
        findShift(prevLuma: prevLuma, curLuma: curLuma, w: w, h: h,
                  expected: expected, axis: axis,
                  prevConstantFraction: nil, curConstantFraction: nil)
    }

    private static func findShift(prevLuma: [UInt8], curLuma: [UInt8], w: Int, h: Int,
                                  expected: (dx: Int, dy: Int)?, axis: Axis?,
                                  prevConstantFraction: Double?, curConstantFraction: Double?) -> Shift? {
        guard prevLuma.count == curLuma.count, w > 0, h > 0 else { return nil }
        let scale = min(w, h) >= 240 ? 4 : 2
        let dw = max(1, w / scale)
        let dh = max(1, h / scale)
        let ignoredTopRows = stationaryTopRows(prevLuma, curLuma, w, h)
        let ignoredBottomRows = stationaryBottomRows(prevLuma, curLuma, w, h)
        let minProgress = max(1, min(dw, dh) / 30)

        let stationary = sad(prev: prevLuma, cur: curLuma, w: w, h: h, dx: 0, dy: 0, step: scale,
                     ignoreTopRows: ignoredTopRows, ignoreBottomRows: ignoredBottomRows).score
        let prevConstant = prevConstantFraction ?? constantContentFraction(prevLuma, w, h)
        let curConstant = curConstantFraction ?? constantContentFraction(curLuma, w, h)
        let constantPair = prevConstant > 0.58 && curConstant > 0.58
        let informative = constantPair ? informativeLumaDifference(prevLuma, curLuma, w, h) : (avgDiff: 0.0, count: 0)
        if stationary <= 2 && !(constantPair && informative.count > 0 && informative.avgDiff >= 1) {
            return nil
        }

        func shiftImprovesStationary(_ score: Double, dx: Int, dy: Int) -> Bool {
            guard score.isFinite, stationary.isFinite else { return false }
            if stationary <= 1 {
                return score + 0.25 < stationary || coherentShiftSupport(prev: prevLuma, cur: curLuma, w: w, h: h,
                                                                          dx: dx, dy: dy,
                                                                          ignoreTopRows: ignoredTopRows,
                                                                          ignoreBottomRows: ignoredBottomRows)
            }
            if score + 1.0 < stationary && score * 100 < stationary * 92 { return true }
            return coherentShiftSupport(prev: prevLuma, cur: curLuma, w: w, h: h,
                                        dx: dx, dy: dy,
                                        ignoreTopRows: ignoredTopRows,
                                        ignoreBottomRows: ignoredBottomRows)
        }

        func finishVertical(fullResolutionShift: Int, score: Double) -> Shift? {
            let refined = refineWindow(prev: prevLuma, cur: curLuma, w: w, h: h,
                                       dxCenter: 0, dyCenter: fullResolutionShift,
                                       dxRadius: 0, dyRadius: max(1, scale),
                                       ignoreTopRows: ignoredTopRows, ignoreBottomRows: ignoredBottomRows)
            guard shiftImprovesStationary(refined.score, dx: 0, dy: refined.dy) else { return nil }
            return Shift(dx: 0, dy: refined.dy, axis: .vertical, score: score)
        }

        func finishHorizontal(fullResolutionShift: Int, score: Double) -> Shift? {
            let refined = refineWindow(prev: prevLuma, cur: curLuma, w: w, h: h,
                                       dxCenter: fullResolutionShift, dyCenter: 0,
                                       dxRadius: max(1, scale), dyRadius: 0)
            guard shiftImprovesStationary(refined.score, dx: refined.dx, dy: 0) else { return nil }
            return Shift(dx: refined.dx, dy: 0, axis: .horizontal, score: score)
        }

        func fixedHeaderVerticalShift(center: Int?, radius: Int?) -> Shift? {
            guard ignoredTopRows >= max(8, h / 40) else { return nil }
            let maxShift = h - max(8, h / 8)
            let lo: Int, hi: Int
            if let center, let radius {
                lo = max(-maxShift, center - radius)
                hi = min(maxShift, center + radius)
            } else {
                lo = -maxShift
                hi = maxShift
            }
            guard let best = informativeVerticalSADShift(prev: prevLuma, cur: curLuma, w: w, h: h,
                                                         lo: lo, hi: hi, minAbsShift: minProgress * scale,
                                                         ignoreTopRows: ignoredTopRows, ignoreBottomRows: ignoredBottomRows) ??
                bestVerticalSADShift(prev: prevLuma, cur: curLuma, w: w, h: h,
                                     lo: lo, hi: hi, minAbsShift: minProgress * scale,
                                     ignoreTopRows: ignoredTopRows, ignoreBottomRows: ignoredBottomRows) else { return nil }
            let refined = refineWindow(prev: prevLuma, cur: curLuma, w: w, h: h,
                                       dxCenter: 0, dyCenter: best.dy,
                                       dxRadius: 0, dyRadius: max(1, scale),
                                       ignoreTopRows: ignoredTopRows, ignoreBottomRows: ignoredBottomRows)
            guard shiftImprovesStationary(refined.score, dx: 0, dy: refined.dy) else { return nil }
            return Shift(dx: 0, dy: refined.dy, axis: .vertical, score: 1.0)
        }

        if let axis {
            let exp = expected ?? (0, 0)
            func isUsableWindowedShift(_ shift: Int, expected: Int) -> Bool {
                guard abs(shift) >= max(minProgress, 2) else { return false }
                let minimumUsefulShift = max(minProgress * scale, abs(expected) / 2)
                if abs(shift) <= minimumUsefulShift { return false }
                if expected != 0 && (shift > 0) != (expected > 0) { return false }
                return true
            }

            switch axis {
            case .vertical:
                let radiusPx = max(minProgress * scale * 3, abs(exp.dy) / 2 + scale * 4)
                if let shift = fixedHeaderVerticalShift(center: exp.dy, radius: radiusPx),
                   isUsableWindowedShift(shift.dy, expected: exp.dy) {
                    return shift
                }
                // Global-minimum SAD scan on informative pixels finds the true
                // shift even for fast scrolls; this avoids the harmonic aliasing
                // that an edge-density NCC produces on repetitive text.
                if let windowed = axisScan(prev: prevLuma, cur: curLuma, w: w, h: h,
                                           ignoreTopRows: ignoredTopRows, lockedAxis: .vertical,
                                           center: exp.dy, radius: radiusPx),
                   isUsableWindowedShift(windowed.shift, expected: exp.dy) {
                    return finishVertical(fullResolutionShift: windowed.shift, score: 1.0)
                }
                if let full = axisScan(prev: prevLuma, cur: curLuma, w: w, h: h,
                                       ignoreTopRows: ignoredTopRows, lockedAxis: .vertical),
                   isUsableWindowedShift(full.shift, expected: exp.dy) {
                    return finishVertical(fullResolutionShift: full.shift, score: 1.0)
                }
                return nil
            case .horizontal:
                let radiusPx = max(minProgress * scale * 3, abs(exp.dx) / 2 + scale * 4)
                if let windowed = axisScan(prev: prevLuma, cur: curLuma, w: w, h: h,
                                           ignoreTopRows: ignoredTopRows, lockedAxis: .horizontal,
                                           center: exp.dx, radius: radiusPx),
                   isUsableWindowedShift(windowed.shift, expected: exp.dx) {
                    return finishHorizontal(fullResolutionShift: windowed.shift, score: 1.0)
                }
                if let full = axisScan(prev: prevLuma, cur: curLuma, w: w, h: h,
                                       ignoreTopRows: ignoredTopRows, lockedAxis: .horizontal),
                   isUsableWindowedShift(full.shift, expected: exp.dx) {
                    return finishHorizontal(fullResolutionShift: full.shift, score: 1.0)
                }
                return nil
            }
        }

        // First pair: discover the dominant axis.
        if let shift = fixedHeaderVerticalShift(center: nil, radius: nil) {
            return shift
        }
        if let axisDecision = axisScan(prev: prevLuma, cur: curLuma, w: w, h: h, ignoreTopRows: ignoredTopRows) {
            switch axisDecision.axis {
            case .vertical:
                if abs(axisDecision.shift) >= minProgress {
                    return finishVertical(fullResolutionShift: axisDecision.shift, score: 1.0)
                }
            case .horizontal:
                if abs(axisDecision.shift) >= minProgress {
                    return finishHorizontal(fullResolutionShift: axisDecision.shift, score: 1.0)
                }
            }
        }
        return nil
    }

    // MARK: - Composition

    /// Stitch the accepted frames into a single panorama image. Frames are
    /// composed in capture order with later (newer) frames overwriting earlier
    /// ones, so each region shows its most recently captured rendering.
    public static func stitch(frames: [Frame], progress: ((Int) -> Void)? = nil, isCancelled: (() -> Bool)? = nil) -> Frame? {
        guard let first = frames.first else { return nil }
        let w = first.width
        let h = first.height
        guard w > 0, h > 0 else { return nil }
        if frames.count == 1 { return first }

        // Instrumentation: set ZOOMIT_PANO_PROFILE=1 to trace every phase to
        // stderr, flushed immediately. If the stitch hangs, the LAST printed
        // line pinpoints the frame/phase it is stuck in. ZOOMIT_PANO_PROFILE=2
        // also logs per-frame match timings.
        let profileLevel = Int(ProcessInfo.processInfo.environment["ZOOMIT_PANO_PROFILE"] ?? "") ?? 0
        let stitchStart = DispatchTime.now()
        func elapsedMs(_ since: DispatchTime) -> Double {
            Double(DispatchTime.now().uptimeNanoseconds &- since.uptimeNanoseconds) / 1_000_000
        }
        func plog(_ message: @autoclosure () -> String) {
            guard profileLevel > 0 else { return }
            FileHandle.standardError.write("[pano +\(String(format: "%.0f", elapsedMs(stitchStart)))ms] \(message())\n".data(using: .utf8)!)
        }
        plog("begin frames=\(frames.count) frame=\(w)x\(h)")

        // Compute luma incrementally rather than precomputing every frame's luma
        // up front: panorama runs can hold hundreds of full-resolution frames,
        // and keeping a luma plane for each on top of the RGBA pixels can exhaust
        // memory and stall the whole stitch. Only the most recently composed
        // frame's luma is needed as the alignment reference.
        // The first captured frame is a warm-up (soft/blurry); skip it so the
        // panorama top is sharp. Base on the second frame.
        var startIndex = frames.count > 12 ? 1 : 0
        var referenceLuma = luma(frames[startIndex])
        var referenceConstantFraction = constantContentFraction(referenceLuma, w, h)
        var composedIndices = [startIndex]
        var origins: [(x: Int, y: Int)] = [(0, 0)]
        var steps: [(x: Int, y: Int)] = [(0, 0)]
        var expected: (dx: Int, dy: Int)?
        var axis: Axis?
        // Committed direction sign on the locked axis (-1/+1). Like Windows, do
        // not lock a direction until it's clear: the first accepted shift is
        // tentative; if the next shift reverses, the tentative base was a
        // pre-scroll jitter, so rebase onto the newer frame instead of stitching
        // one way then switching (which corrupts the top of the panorama).
        var committedSign = 0
        var directionConfirmed = false
        // Windows-style guards: never accept a sub-progress step (would stamp a
        // near-duplicate sliver and repeat content), and reject spikes that
        // deviate wildly from the established per-frame step (harmonic aliases).
        let minProgress = max(8, min(w, h) / 30)
        var acceptedSteps: [Int] = []

        for i in (startIndex + 1)..<frames.count {
            if isCancelled?() == true { return nil }
            progress?(5 + i * 85 / frames.count)
            guard frames[i].width == w, frames[i].height == h else { continue }
            let matchStart = DispatchTime.now()
            if profileLevel >= 2 { plog("frame \(i)/\(frames.count - 1) match start expected=\(expected.map { "(\($0.dx),\($0.dy))" } ?? "nil") axis=\((directionConfirmed ? axis : nil).map { "\($0)" } ?? "first-pair")") }
            let curLuma = luma(frames[i])
            let curConstantFraction = constantContentFraction(curLuma, w, h)
            let searchAxis = directionConfirmed ? axis : nil
            var nextExpectedOverride: (dx: Int, dy: Int)?
            var shift = findShift(prevLuma: referenceLuma, curLuma: curLuma, w: w, h: h,
                                  expected: expected, axis: searchAxis,
                                  prevConstantFraction: referenceConstantFraction,
                                  curConstantFraction: curConstantFraction)
            if shift == nil,
               directionConfirmed,
               let axis,
               let expected,
               i > startIndex + 1,
               frames[i - 1].width == w,
               frames[i - 1].height == h {
                if profileLevel >= 2 { plog("frame \(i) primary miss -> adjacent recovery") }
                let previousCapturedLuma = luma(frames[i - 1])
                if let adjacent = findShift(prevLuma: previousCapturedLuma, curLuma: curLuma, w: w, h: h,
                                            expected: expected, axis: axis) {
                    let expectedPrimary = axis == .horizontal ? expected.dx : expected.dy
                    let adjacentPrimary = axis == .horizontal ? adjacent.dx : adjacent.dy
                    let adjacentAbs = abs(adjacentPrimary)
                    let sameDirection = expectedPrimary == 0 || adjacentPrimary == 0 || (expectedPrimary > 0) == (adjacentPrimary > 0)
                    let minRecoveredStep = max(4, minProgress / 2)
                    let maxRecoveredStep = min(axis == .horizontal ? w - minProgress : h - minProgress,
                                               max(abs(expectedPrimary) * 2, minProgress * 6))
                    if sameDirection && adjacentAbs >= minRecoveredStep && adjacentAbs <= maxRecoveredStep {
                        let gap = max(1, i - composedIndices[composedIndices.count - 1])
                        let maxTotal = axis == .horizontal ? w - minProgress : h - minProgress
                        let recoveredPrimary = max(-maxTotal, min(maxTotal, adjacentPrimary * gap))
                        shift = axis == .horizontal
                            ? Shift(dx: recoveredPrimary, dy: 0, axis: .horizontal, score: adjacent.score)
                            : Shift(dx: 0, dy: recoveredPrimary, axis: .vertical, score: adjacent.score)
                        nextExpectedOverride = (adjacent.dx, adjacent.dy)
                    }
                }
            }
            guard let shift else { continue }
            if shift.dx == 0 && shift.dy == 0 { continue }

            let matchMs = elapsedMs(matchStart)
            // Even at level 1, flag a frame whose match is pathologically slow:
            // a hang shows up as one frame that never prints its "done" line, or
            // a steadily climbing per-frame time.
            if profileLevel >= 2 || matchMs > 250 {
                plog("frame \(i) match done \(String(format: "%.0f", matchMs))ms shift=(\(shift.dx),\(shift.dy))")
            }

            let primary = shift.axis == .horizontal ? shift.dx : shift.dy
            let sign = primary > 0 ? 1 : -1
            let absStep = abs(primary)
            // Drop sub-progress steps: too small to be real scroll, they stamp
            // repeated near-duplicate bands.
            if absStep < minProgress { continue }
            // Spike guard: once a steady step is known, reject a step that jumps
            // far beyond it (harmonic alias) so we don't tile the same region.
            if directionConfirmed, acceptedSteps.count >= 3 {
                let sorted = acceptedSteps.sorted()
                let median = sorted[sorted.count / 2]
                if absStep > max(median * 3, median + 64) { continue }
            }

            if committedSign == 0 {
                // First accepted step: commit the axis now so momentum windowing
                // prevents harmonic small-shift aliasing, but treat the direction
                // as tentative until a second step confirms it.
                committedSign = sign
                axis = shift.axis
            } else if sign != committedSign {
                if !directionConfirmed {
                    // Reversal before confirmation: the base was pre-scroll
                    // jitter. Rebase onto the pivot and recompute, never
                    // stitching one way then switching.
                    let pivot = composedIndices[composedIndices.count - 1]
                    referenceLuma = luma(frames[pivot])
                    referenceConstantFraction = constantContentFraction(referenceLuma, w, h)
                    origins = [(0, 0)]
                    steps = [(0, 0)]
                    composedIndices = [pivot]
                    expected = nil
                    committedSign = 0
                    axis = nil
                    continue
                }
                // Direction locked: ignore spurious opposite-sign matches.
                continue
            } else {
                directionConfirmed = true
            }

            let last = origins[origins.count - 1]
            origins.append((x: last.x + shift.dx, y: last.y + shift.dy))
            steps.append((x: shift.dx, y: shift.dy))
            composedIndices.append(i)
            expected = nextExpectedOverride ?? (shift.dx, shift.dy)
            acceptedSteps.append(absStep)
            referenceLuma = curLuma
            referenceConstantFraction = curConstantFraction
            if ProcessInfo.processInfo.environment["ZOOMIT_PANO_LOG"] != nil {
                FileHandle.standardError.write("accept i=\(i) dx=\(shift.dx) dy=\(shift.dy)\n".data(using: .utf8)!)
            }
        }

        var minX = 0, minY = 0, maxX = w, maxY = h
        for origin in origins {
            minX = min(minX, origin.x)
            minY = min(minY, origin.y)
            maxX = max(maxX, origin.x + w)
            maxY = max(maxY, origin.y + h)
        }
        let canvasW = maxX - minX
        let canvasH = maxY - minY
        guard canvasW > 0, canvasH > 0 else { return nil }
        plog("alignment done composed=\(composedIndices.count)/\(frames.count) canvas=\(canvasW)x\(canvasH)")

        // Composite onto the canvas using the Windows panorama model: pixels in
        // the deep overlap keep the old canvas, the new strip uses the new
        // frame, and a narrow seam band feathers between them.
        var canvas = [UInt8](repeating: 0, count: canvasW * canvasH * 4)
        var written = [Bool](repeating: false, count: canvasW * canvasH)
        let resolvedAxis = axis ?? .vertical
        let fixedTopHeaderHeight = fixedTopHeaderHeight(frames: frames, composedIndices: composedIndices,
                                steps: steps, axis: axis, w: w, h: h)
        let fixedBottomFooterHeight = fixedBottomFooterHeight(frames: frames, composedIndices: composedIndices,
                                steps: steps, axis: axis, w: w, h: h)
        let featherBase = resolvedAxis == .horizontal ? w : h
        // Keep the seam crossfade very narrow: a wide feather blends slightly
        // misaligned overlap rows and ghosts the image. A hard-ish seam keeps
        // every pixel from a single frame so the panorama stays sharp.
        let feather = max(1, min(3, featherBase / 120))

        let composeStart = DispatchTime.now()
        plog("compose start frames=\(composedIndices.count) header=\(fixedTopHeaderHeight) footer=\(fixedBottomFooterHeight)")
        for (k, index) in composedIndices.enumerated() {
            if isCancelled?() == true { return nil }
            let origin = origins[k]
            compose(src: frames[index].pixels, srcW: w, srcH: h,
                    dst: &canvas, written: &written, dstW: canvasW, dstH: canvasH,
                    originX: origin.x - minX, originY: origin.y - minY,
                    axis: resolvedAxis, step: steps[k], feather: feather,
                    suppressTopRows: k == 0 ? 0 : fixedTopHeaderHeight,
                    suppressBottomRows: k == composedIndices.count - 1 ? 0 : fixedBottomFooterHeight)
        }
        plog("compose done \(String(format: "%.0f", elapsedMs(composeStart)))ms")

        let repairStart = DispatchTime.now()
        repairUnwrittenPixels(dst: &canvas, written: &written, dstW: canvasW, dstH: canvasH)
        plog("repair done \(String(format: "%.0f", elapsedMs(repairStart)))ms")

        progress?(100)
        plog("stitch done total=\(String(format: "%.0f", elapsedMs(stitchStart)))ms size=\(canvasW)x\(canvasH)")
        return Frame(width: canvasW, height: canvasH, pixels: canvas)
    }

    /// Weight (0...1) of the *new* frame at position `pos` along the scroll
    /// axis. Pixels deep inside the previously-captured region keep the old
    /// canvas (weight 0); the genuinely new strip uses the new frame (weight 1);
    /// a `feather`-wide band at the seam ramps linearly between them. `step` is
    /// the signed inter-frame displacement on this axis (positive = new content
    /// appears at the far/high-index edge).
    private static func newWeight(pos: Int, size: Int, step: Int, feather: Int) -> Double {
        if step >= 0 {
            // New content occupies the high indices [size - step, size).
            let seam = size - step
            if pos >= seam { return 1 }
            if pos > seam - feather { return Double(pos - (seam - feather)) / Double(feather) }
            return 0
        } else {
            // New content occupies the low indices [0, -step).
            let s = -step
            if pos < s { return 1 }
            if pos < s + feather { return 1 - Double(pos - s) / Double(feather) }
            return 0
        }
    }

    private static func compose(src: [UInt8], srcW: Int, srcH: Int,
                                dst: inout [UInt8], written: inout [Bool], dstW: Int, dstH: Int,
                                originX: Int, originY: Int,
                                axis: Axis, step: (x: Int, y: Int), feather: Int,
                                suppressTopRows: Int, suppressBottomRows: Int = 0) {
        src.withUnsafeBufferPointer { ps in
            dst.withUnsafeMutableBufferPointer { pd in
                written.withUnsafeMutableBufferPointer { pw in
                    DispatchQueue.concurrentPerform(iterations: srcH) { y in
                        if y < suppressTopRows { return }
                        if suppressBottomRows > 0 && y >= srcH - suppressBottomRows { return }
                        let dy = originY + y
                        if dy < 0 || dy >= dstH { return }
                        let srcRow = y * srcW * 4
                        let dstRowPx = dy * dstW
                        // Vertical scroll uses keep-first (the first frame to
                        // cover a pixel wins): later frames only fill their new
                        // strip. Unlike Windows -- whose fine matcher reaches
                        // near-perfect sub-pixel alignment and can afford a seam
                        // feather -- the Mac matcher is coarser, so blending the
                        // overlap ghosts slightly-misaligned text into a visible
                        // dark band. Keep-first always takes a single frame's
                        // pixels per canvas pixel, so text stays sharp. Genuine
                        // unwritten gaps are filled afterward by repairUnwrittenPixels.
                        if axis == .vertical {
                            if originX == 0 && srcW == dstW {
                                if !pw[dstRowPx] {
                                    pd.baseAddress!.advanced(by: dstRowPx * 4)
                                        .update(from: ps.baseAddress!.advanced(by: srcRow), count: srcW * 4)
                                    for px in dstRowPx..<(dstRowPx + srcW) { pw[px] = true }
                                }
                                return
                            }
                            for x in 0..<srcW {
                                let dx = originX + x
                                if dx < 0 || dx >= dstW { continue }
                                let wi = dstRowPx + dx
                                if pw[wi] { continue }
                                let si = srcRow + x * 4, di = wi * 4
                                pd[di] = ps[si]; pd[di + 1] = ps[si + 1]
                                pd[di + 2] = ps[si + 2]; pd[di + 3] = 255
                                pw[wi] = true
                            }
                            return
                        }
                        for x in 0..<srcW {
                            let dx = originX + x
                            if dx < 0 || dx >= dstW { continue }
                            let si = srcRow + x * 4
                            let di = (dstRowPx + dx) * 4
                            let wi = dstRowPx + dx
                            if !pw[wi] {
                                // First frame to reach this pixel: copy it.
                                pd[di] = ps[si]; pd[di + 1] = ps[si + 1]
                                pd[di + 2] = ps[si + 2]; pd[di + 3] = 255
                                pw[wi] = true
                                continue
                            }
                            // Horizontal overlap: narrow feather crossfade.
                            let weight = newWeight(pos: x, size: srcW, step: step.x, feather: feather)
                            if weight <= 0 { continue }
                            if weight >= 1 {
                                pd[di] = ps[si]; pd[di + 1] = ps[si + 1]
                                pd[di + 2] = ps[si + 2]; pd[di + 3] = 255
                            } else {
                                let nw = weight, ow = 1 - weight
                                pd[di] = UInt8(Double(ps[si]) * nw + Double(pd[di]) * ow)
                                pd[di + 1] = UInt8(Double(ps[si + 1]) * nw + Double(pd[di + 1]) * ow)
                                pd[di + 2] = UInt8(Double(ps[si + 2]) * nw + Double(pd[di + 2]) * ow)
                                pd[di + 3] = 255
                            }
                        }
                    }
                }
            }
        }
    }

    private static func repairUnwrittenPixels(dst: inout [UInt8], written: inout [Bool], dstW: Int, dstH: Int) {
        guard dstW > 0, dstH > 0, dst.count == dstW * dstH * 4, written.count == dstW * dstH else { return }
        for x in 0..<dstW {
            var y = 0
            while y < dstH {
                let pixelIndex = y * dstW + x
                if written[pixelIndex] {
                    y += 1
                    continue
                }

                let runStart = y
                while y < dstH && !written[y * dstW + x] {
                    y += 1
                }
                let runEnd = y - 1

                var aboveY = runStart - 1
                while aboveY >= 0 && !written[aboveY * dstW + x] {
                    aboveY -= 1
                }
                var belowY = runEnd + 1
                while belowY < dstH && !written[belowY * dstW + x] {
                    belowY += 1
                }

                let hasAbove = aboveY >= 0
                let hasBelow = belowY < dstH
                if !hasAbove && !hasBelow { continue }

                for fillY in runStart...runEnd {
                    let fillPixelIndex = fillY * dstW + x
                    let fillColorIndex = fillPixelIndex * 4
                    if hasAbove && hasBelow && belowY > aboveY {
                        let numerator = fillY - aboveY
                        let denominator = belowY - aboveY
                        let aboveColorIndex = (aboveY * dstW + x) * 4
                        let belowColorIndex = (belowY * dstW + x) * 4
                        for channel in 0..<3 {
                            let above = Int(dst[aboveColorIndex + channel])
                            let below = Int(dst[belowColorIndex + channel])
                            dst[fillColorIndex + channel] = UInt8((above * (denominator - numerator) + below * numerator) / max(1, denominator))
                        }
                    } else {
                        let sourceY = hasAbove ? aboveY : belowY
                        let sourceColorIndex = (sourceY * dstW + x) * 4
                        dst[fillColorIndex] = dst[sourceColorIndex]
                        dst[fillColorIndex + 1] = dst[sourceColorIndex + 1]
                        dst[fillColorIndex + 2] = dst[sourceColorIndex + 2]
                    }
                    dst[fillColorIndex + 3] = 255
                    written[fillPixelIndex] = true
                }
            }
        }
    }
}
