//
//  NegPipeline.swift
//  NegClone – density-space color negative conversion (macOS)
//
//  Clean-room Swift reimplementation of the density-space negative inversion
//  pipeline (same family as darktable negadoctor / DiVERE):
//
//    linear -> density -> invert (pivot/gamma/dmax) -> linear
//      -> density -> matrix -> gains -> curves -> linear -> sRGB
//
//  Only the published mathematical approach is used; no proprietary code
//  is copied. Reference: darktable src/iop/negadoctor.c (GPL).
//

import Foundation
import Accelerate

// MARK: - Parameters

public struct NegParameters {
    public var densityGamma: Float = 1.0
    public var densityDMax: Float = 2.2 // validated on real PRO 400H scan

    /// 3x3 density-space color correction matrix (row-major).
    public var matrix: (Float, Float, Float,
                        Float, Float, Float,
                        Float, Float, Float) =
        (1.0197, 0.0317, 0.0091,
         -0.0052, 0.8933, 0.0521,
         0.0131, -0.0011, 0.9712)
    public var useMatrix: Bool = true

    /// Per-channel gamma around the matrix pivot (R, G, B).
    public var channelGamma: (Float, Float, Float) = (1.0, 1.0, 1.0)
    public var useChannelGamma: Bool = false

    /// Per-channel density gains (R, G, B).
    public var rgbGains: (Float, Float, Float) = (0.0, 0.0, 0.0)
    public var useGains: Bool = false

    /// Paper curve points (x, y) in normalized density; nil = skip.
    public var curveRGB: [(Float, Float)]? = nil

    /// Screen glare compensation in percent (0 ... 5).
    public var screenGlare: Float = 0
    /// Per-channel curves: 3 channels x 5 control points (y values at
    /// x = 0, 0.25, 0.5, 0.75, 1.0). Applied in display space.
    public var curves: [[Float]] = [[0, 0.25, 0.5, 0.75, 1] as [Float],
                                   [0, 0.25, 0.5, 0.75, 1] as [Float],
                                   [0, 0.25, 0.5, 0.75, 1] as [Float]]

    public init() {}
}

// MARK: - Pipeline

public enum NegPipeline {

    private static let log65536: Float = 4.816479930623698  // log10(65536)
    private static let pivotInv: Float = 0.7
    private static let pivotMat: Float = 4.1
    private static let ln10: Float = 2.302585092994046

    /// Convert a scanned negative (linear RGB, 0...1) to a positive image.
    ///
    /// - Parameters:
    ///   - pixels: Interleaved RGBA float pixels, linear light, 0...1.
    ///   - width: Image width in pixels.
    ///   - height: Image height in pixels.
    ///   - params: Conversion parameters.
    /// - Returns: Interleaved RGBA float pixels of the positive image, 0...1.
    public static func process(pixels: [Float],
                               width: Int,
                               height: Int,
                               params: NegParameters) -> [Float] {
        let count = width * height
        precondition(pixels.count >= count * 4)

        var r = [Float](repeating: 0, count: count)
        var g = [Float](repeating: 0, count: count)
        var b = [Float](repeating: 0, count: count)
        var a = [Float](repeating: 0, count: count)
        for i in 0..<count {
            r[i] = pixels[i * 4]
            g[i] = pixels[i * 4 + 1]
            b[i] = pixels[i * 4 + 2]
            a[i] = pixels[i * 4 + 3]
        }

        // 1. density inversion: density = -log10(pixel),
        //    then pivot + (density - pivot) * gamma - dmax, back to linear.
        invertDensity(&r, gamma: params.densityGamma, dmax: params.densityDMax)
        invertDensity(&g, gamma: params.densityGamma, dmax: params.densityDMax)
        invertDensity(&b, gamma: params.densityGamma, dmax: params.densityDMax)

        // 2. back to density
        toDensity(&r); toDensity(&g); toDensity(&b)

        // 3. density matrix + channel gamma around pivotMat
        if params.useMatrix || params.useChannelGamma {
            applyMatrixAndGamma(&r, &g, &b, params: params)
        }

        // 4. RGB gains in density
        if params.useGains {
            let gr = params.rgbGains.0, gg = params.rgbGains.1, gb = params.rgbGains.2
            vDSP.add(-gr, r, result: &r)
            vDSP.add(-gg, g, result: &g)
            vDSP.add(-gb, b, result: &b)
        }

        // 5. paper curves
        if let curve = params.curveRGB {
            applyCurve(&r, points: curve)
            applyCurve(&g, points: curve)
            applyCurve(&b, points: curve)
        }

        // 6. density -> linear, clipped
        toLinear(&r); toLinear(&g); toLinear(&b)

        // 7. screen glare compensation
        if params.screenGlare > 0 {
            let glare = params.screenGlare / 100.0
            for i in 0..<count {
                r[i] = max(0, r[i] - glare)
                g[i] = max(0, g[i] - glare)
                b[i] = max(0, b[i] - glare)
            }
        }

        var out = [Float](repeating: 0, count: count * 4)
        for i in 0..<count {
            out[i * 4] = r[i]
            out[i * 4 + 1] = g[i]
            out[i * 4 + 2] = b[i]
            out[i * 4 + 3] = a[i]
        }
        return out
    }

    // MARK: - Stages

    private static func invertDensity(_ c: inout [Float], gamma: Float, dmax: Float) {
        let n = c.count
        // density = -log10(max(c, 1e-10))
        var tmp = [Float](repeating: 0, count: n)
        vDSP.clip(c, to: 1e-10...Float.greatestFiniteMagnitude, result: &tmp)
        vForce.log10(tmp, result: &tmp)
        vDSP.multiply(-1, tmp, result: &tmp)
        // adjusted = pivot + (density - pivot) * gamma - dmax
        var adj = [Float](repeating: 0, count: n)
        vDSP.add(-pivotInv, tmp, result: &adj)
        vDSP.multiply(gamma, adj, result: &adj)
        vDSP.add(pivotInv - dmax, adj, result: &adj)
        // linear = exp(adjusted * ln10)
        vDSP.multiply(ln10, adj, result: &adj)
        vForce.exp(adj, result: &c)
    }

    private static func toDensity(_ c: inout [Float]) {
        let n = c.count
        var tmp = [Float](repeating: 0, count: n)
        vDSP.clip(c, to: 1e-10...Float.greatestFiniteMagnitude, result: &tmp)
        vForce.log10(tmp, result: &tmp)
        vDSP.multiply(-1, tmp, result: &c)
    }

    private static func toLinear(_ c: inout [Float]) {
        let n = c.count
        var tmp = [Float](repeating: 0, count: n)
        vDSP.multiply(-ln10, c, result: &tmp)
        vForce.exp(tmp, result: &tmp)
        vDSP.clip(tmp, to: 0...1, result: &c)
    }

    private static func applyMatrixAndGamma(_ r: inout [Float],
                                            _ g: inout [Float],
                                            _ b: inout [Float],
                                            params: NegParameters) {
        let n = r.count
        let dmax = params.densityDMax
        let m = params.matrix

        var pr = [Float](repeating: 0, count: n)
        var pg = [Float](repeating: 0, count: n)
        var pb = [Float](repeating: 0, count: n)
        vDSP.add(dmax - pivotMat, r, result: &pr)
        vDSP.add(dmax - pivotMat, g, result: &pg)
        vDSP.add(dmax - pivotMat, b, result: &pb)

        var nr = [Float](repeating: 0, count: n)
        var ng = [Float](repeating: 0, count: n)
        var nb = [Float](repeating: 0, count: n)
        if params.useMatrix {
            for i in 0..<n {
                nr[i] = pivotMat + pr[i] * m.0 + pg[i] * m.1 + pb[i] * m.2
                ng[i] = pivotMat + pr[i] * m.3 + pg[i] * m.4 + pb[i] * m.5
                nb[i] = pivotMat + pr[i] * m.6 + pg[i] * m.7 + pb[i] * m.8
            }
        } else {
            vDSP.add(pivotMat, pr, result: &nr)
            vDSP.add(pivotMat, pg, result: &ng)
            vDSP.add(pivotMat, pb, result: &nb)
        }

        if params.useChannelGamma {
            let cg = params.channelGamma
            for i in 0..<n {
                nr[i] = pivotMat + (nr[i] - pivotMat) * cg.0
                ng[i] = pivotMat + (ng[i] - pivotMat) * cg.1
                nb[i] = pivotMat + (nb[i] - pivotMat) * cg.2
            }
        }

        vDSP.add(-dmax, nr, result: &r)
        vDSP.add(-dmax, ng, result: &g)
        vDSP.add(-dmax, nb, result: &b)
    }

    private static func applyCurve(_ c: inout [Float], points: [(Float, Float)]) {
        let inv = 1.0 / log65536
        let xs = points.map { $0.0 }
        let ys = points.map { $0.1 }
        for i in 0..<c.count {
            let norm = 1.0 - min(1.0, max(0.0, c[i] * inv))
            let y = interpLinear(x: norm, xs: xs, ys: ys)
            c[i] = (1.0 - y) * log65536
        }
    }

    private static func interpLinear(x: Float, xs: [Float], ys: [Float]) -> Float {
        guard xs.count > 1 else { return ys.first ?? 0 }
        if x <= xs[0] { return ys[0] }
        if x >= xs[xs.count - 1] { return ys[ys.count - 1] }
        for k in 0..<(xs.count - 1) {
            if x >= xs[k] && x <= xs[k + 1] {
                let t = (x - xs[k]) / (xs[k + 1] - xs[k])
                return ys[k] + t * (ys[k + 1] - ys[k])
            }
        }
        return ys[ys.count - 1]
    }

    // MARK: - Auto white balance

    /// Sample the film base (unexposed border) and return per-channel medians.
    /// - Parameters:
    ///   - pixels: Interleaved RGBA linear floats.
    ///   - width, height: Image dimensions.
    ///   - region: (x0, x1, y0, y1) pixel bounds of the base sample area.
    public static func sampleFilmBase(pixels: [Float], width: Int, height: Int,
                                      region: (Int, Int, Int, Int)) -> (Float, Float, Float) {
        let (x0, x1, y0, y1) = region
        var rs = [Float](), gs = [Float](), bs = [Float]()
        rs.reserveCapacity((x1 - x0) * (y1 - y0))
        gs.reserveCapacity((x1 - x0) * (y1 - y0))
        bs.reserveCapacity((x1 - x0) * (y1 - y0))
        for y in y0..<y1 {
            for x in x0..<x1 {
                let i = (y * width + x) * 4
                rs.append(pixels[i]); gs.append(pixels[i + 1]); bs.append(pixels[i + 2])
            }
        }
        return (median(rs), median(gs), median(bs))
    }

    /// WB multipliers that neutralize the film base (orange-mask removal).
    /// Clamped to [0.2, 20] so a bad sample (e.g. no border in frame)
    /// can't produce insane multipliers.
    public static func baseWBMultipliers(base: (Float, Float, Float)) -> (Float, Float, Float) {
        let m = (base.0 + base.1 + base.2) / 3
        func cl(_ v: Float) -> Float { min(20, max(0.2, v)) }
        return (cl(m / max(base.0, 1e-6)), cl(m / max(base.1, 1e-6)), cl(m / max(base.2, 1e-6)))
    }

    /// Refine WB from a first conversion: the base B channel often sits near
    /// the sensor black level (low SNR), so its mask estimate can be off by a
    /// systematic factor. Measure median R/G and B/G over the positive and
    /// fold the residual back into the (negative-domain) multipliers.
    /// Corrections are clamped to [0.5, 2.0].
    public static func refineWB(positive: [Float], wb: (Float, Float, Float))
        -> (Float, Float, Float) {
        let count = positive.count / 4
        var rg = [Float](), bg = [Float]()
        rg.reserveCapacity(count); bg.reserveCapacity(count)
        for i in 0..<count {
            let g = max(positive[i * 4 + 1], 1e-6)
            rg.append(positive[i * 4] / g)
            bg.append(positive[i * 4 + 2] / g)
        }
        let cr = min(2.0, max(0.5, median(rg)))
        let cb = min(2.0, max(0.5, median(bg)))
        return (wb.0 * cr, wb.1, wb.2 * cb)
    }

    /// Apply WB multipliers to interleaved RGBA linear pixels (in place).
    public static func applyWB(_ pixels: inout [Float], wb: (Float, Float, Float)) {
        let count = pixels.count / 4
        for i in 0..<count {
            pixels[i * 4] *= wb.0
            pixels[i * 4 + 1] *= wb.1
            pixels[i * 4 + 2] *= wb.2
        }
    }

    private static func median(_ v: [Float]) -> Float {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// Automatic dmax: maps the median density of the (white-balanced)
    /// negative to 18% linear gray, the standard auto-exposure anchor.
    /// dmax = gamma*(Dmed - pivot) + pivot - log10(0.18).
    /// Runs on a downsampled subset for speed; result clamped to [1, 4].
    public static func autoDMax(pixels: [Float], width: Int, height: Int,
                                gamma: Float, wb: (Float, Float, Float)) -> Float {
        let count = width * height
        // stride to ~200k samples max
        let stride = max(1, count / 200_000)
        var dens = [Float]()
        dens.reserveCapacity(count / stride * 3)
        var i = 0
        while i < count {
            let o = i * 4
            let r = max(pixels[o] * wb.0, 1e-10)
            let g = max(pixels[o + 1] * wb.1, 1e-10)
            let b = max(pixels[o + 2] * wb.2, 1e-10)
            dens.append(-log10(r)); dens.append(-log10(g)); dens.append(-log10(b))
            i += stride
        }
        // drop clamped outliers (dead pixels)
        dens.removeAll { $0 >= 9.9 }
        guard !dens.isEmpty else { return 2.2 }
        let dmed = median(dens)
        let dmax = gamma * (dmed - pivotInv) + pivotInv - log10(0.18)
        return min(4.0, max(1.0, dmax))
    }

    /// Heuristic: does the sampled base look like an orange-masked film
    /// border (R >> G >> B)? Guards auto-WB on pre-cropped images.
    public static func looksLikeFilmBase(_ base: (Float, Float, Float)) -> Bool {
        guard base.0 > base.1, base.1 > base.2, base.2 > 1e-6 else { return false }
        return base.0 / base.2 > 2.0
    }

    // MARK: - Film profiles

/// Named starting points based on the known look of common color negative
/// films. Each profile tweaks contrast (gamma), saturation (matrix) and
/// color balance around the neutral conversion. Fine-tune with sliders.
public struct FilmProfile: Identifiable, Hashable {
    public let id: String
    public let name: String
    public var gamma: Float
    public var dmaxOffset: Float
    /// Saturation multiplier (1.0 = neutral).
    public var saturation: Float
    /// Warmth shift (-1 cool … +1 warm), applied as R/B gain.
    public var warmth: Float

    public init(id: String, name: String, gamma: Float = 1.0,
                dmaxOffset: Float = 0, saturation: Float = 1.0,
                warmth: Float = 0) {
        self.id = id; self.name = name
        self.gamma = gamma; self.dmaxOffset = dmaxOffset
        self.saturation = saturation; self.warmth = warmth
    }
}

public enum FilmProfiles {
    public static let all: [FilmProfile] = [
        FilmProfile(id: "neutral", name: "中性"),
        FilmProfile(id: "pro400h", name: "Fuji PRO 400H"),
        FilmProfile(id: "portra400", name: "Kodak Portra 400",
                    gamma: 0.95, dmaxOffset: 0.1, saturation: 0.92, warmth: 0.15),
        FilmProfile(id: "portra160", name: "Kodak Portra 160",
                    gamma: 0.92, dmaxOffset: 0.15, saturation: 0.9, warmth: 0.12),
        FilmProfile(id: "ektar", name: "Kodak Ektar 100",
                    gamma: 1.12, dmaxOffset: -0.1, saturation: 1.25, warmth: 0.05),
        FilmProfile(id: "gold200", name: "Kodak Gold 200",
                    gamma: 1.02, dmaxOffset: 0.05, saturation: 1.1, warmth: 0.2),
        FilmProfile(id: "cinestill800t", name: "Cinestill 800T",
                    gamma: 1.05, saturation: 1.05, warmth: -0.15),
    ]

    /// Build a 3x3 matrix from saturation/warmth around the default matrix.
    public static func apply(_ profile: FilmProfile, to params: inout NegParameters) {
        params.densityGamma = profile.gamma
        // start from the calibrated default matrix
        var m = (1.0197 as Float, 0.0317 as Float, 0.0091 as Float,
                 -0.0052 as Float, 0.8933 as Float, 0.0521 as Float,
                 0.0131 as Float, -0.0011 as Float, 0.9712 as Float)
        // saturation: scale off-diagonals
        let s = profile.saturation
        m.1 *= s; m.2 *= s; m.3 *= s; m.5 *= s; m.6 *= s; m.7 *= s
        // warmth: R gain up, B gain down (or reverse)
        let w = profile.warmth
        m.0 *= (1 + w * 0.1); m.8 *= (1 - w * 0.1)
        params.matrix = m
        params.useMatrix = true
        // note: dmaxOffset is applied by the caller on top of auto dmax
    }
}

    /// Crop interleaved RGBA pixels to a unit rect. Returns (pixels, w, h).
    public static func cropPixels(_ pixels: [Float], width: Int, height: Int,
                                  rect: CGRect) -> ([Float], Int, Int) {
        let x0 = max(0, min(width - 1, Int(rect.minX * CGFloat(width))))
        let y0 = max(0, min(height - 1, Int(rect.minY * CGFloat(height))))
        let x1 = max(x0 + 1, min(width, Int(rect.maxX * CGFloat(width))))
        let y1 = max(y0 + 1, min(height, Int(rect.maxY * CGFloat(height))))
        let w = x1 - x0, h = y1 - y0
        var out = [Float](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let src = ((y0 + y) * width + (x0 + x)) * 4
                let dst = (y * w + x) * 4
                out[dst] = pixels[src]
                out[dst + 1] = pixels[src + 1]
                out[dst + 2] = pixels[src + 2]
                out[dst + 3] = pixels[src + 3]
            }
        }
        return (out, w, h)
    }

    /// Evaluate a 5-point curve (y values at x = 0, .25, .5, .75, 1) at t.
    public static func evalCurve(_ points: [Float], t: Float) -> Float {
        let tc = min(1, max(0, t))
        let seg = min(3, Int(tc * 4))
        let f = tc * 4 - Float(seg)
        return points[seg] * (1 - f) + points[seg + 1] * f
    }

    /// Apply per-channel curves in display (sRGB) space.
    public static func applyCurves(r: Float, g: Float, b: Float,
                                   curves: [[Float]]) -> (Float, Float, Float) {
        return (evalCurve(curves[0], t: r),
                evalCurve(curves[1], t: g),
                evalCurve(curves[2], t: b))
    }

    /// Simple dust healing: for each spot, replace a small disc with the
    /// median of the surrounding annulus. Operates on 8-bit RGBA bytes.
    public static func healSpots(_ bytes: inout [UInt8], width: Int, height: Int,
                                 spots: [CGPoint], radius: Int) {
        guard radius > 0, !spots.isEmpty else { return }
        for spot in spots {
            let cx = Int(spot.x * CGFloat(width))
            let cy = Int(spot.y * CGFloat(height))
            // collect annulus pixels (radius*2 to radius*3)
            var samplesR: [UInt8] = [], samplesG: [UInt8] = [], samplesB: [UInt8] = []
            let r2 = radius * 2, r3 = radius * 3
            for dy in -r3...r3 {
                for dx in -r3...r3 {
                    let d2 = dx*dx + dy*dy
                    if d2 < r2*r2 || d2 > r3*r3 { continue }
                    let x = cx + dx, y = cy + dy
                    if x < 0 || x >= width || y < 0 || y >= height { continue }
                    let idx = (y * width + x) * 4
                    samplesR.append(bytes[idx])
                    samplesG.append(bytes[idx+1])
                    samplesB.append(bytes[idx+2])
                }
            }
            guard !samplesR.isEmpty else { continue }
            samplesR.sort(); samplesG.sort(); samplesB.sort()
            let med = samplesR.count / 2
            let mr = samplesR[med], mg = samplesG[med], mb = samplesB[med]
            // fill disc
            for dy in -radius...radius {
                for dx in -radius...radius {
                    if dx*dx + dy*dy > radius*radius { continue }
                    let x = cx + dx, y = cy + dy
                    if x < 0 || x >= width || y < 0 || y >= height { continue }
                    let idx = (y * width + x) * 4
                    bytes[idx] = mr; bytes[idx+1] = mg; bytes[idx+2] = mb
                }
            }
        }
    }

// MARK: - Output

    /// Linear RGB (0...1) -> sRGB (0...1), per-pixel.
    public static func srgbEncode(_ linear: Float) -> Float {
        let a: Float = 0.055
        let v: Float
        if linear <= 0.0031308 {
            v = 12.92 * linear
        } else {
            v = (1 + a) * pow(max(linear, 0), 1 / 2.4) - a
        }
        return min(1, max(0, v))
    }
}
