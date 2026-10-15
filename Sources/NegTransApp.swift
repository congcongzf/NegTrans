//
//  NegTransApp.swift
//  NegTrans – film negative to positive converter for macOS
//

import SwiftUI
import AppKit
import CoreImage
import UniformTypeIdentifiers

// FilmProfile/FilmProfiles are nested in NegPipeline; alias for convenience.
typealias FilmProfile = NegPipeline.FilmProfile
typealias FilmProfiles = NegPipeline.FilmProfiles

@main
struct NegTransApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1000, minHeight: 700)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

// MARK: - Main view

struct ContentView: View {
    @StateObject private var model = NegModel()
    @State private var showBatch = false
    @State private var cropping = false
    @State private var healing = false

    var body: some View {
        NavigationSplitView {
            // Sidebar: controls
            Form {
                Section("底片反转") {
                    Picker("胶片", selection: $model.selectedProfile) {
                        ForEach(FilmProfiles.all) { profile in
                            Text(profile.name).tag(profile)
                        }
                    }
                    .onChange(of: model.selectedProfile) { _, new in
                        model.applyProfile(new)
                    }

                    Button("自动调整") { model.autoAdjust() }
                        .disabled(!model.hasImage)
                    Button(cropping ? "完成裁切" : "裁切…") {
                        if cropping { cropping = false }
                        else if model.hasImage { cropping = true }
                    }
                    .disabled(!model.hasImage)
                    if model.cropRect != nil {
                        Button("清除裁切") { model.cropRect = nil }
                    }
                    Button(healing ? "完成修复" : "灰尘修复…") {
                        if healing { healing = false }
                        else if model.hasImage { healing = true }
                    }
                    .disabled(!model.hasImage)
                    if !model.healSpots.isEmpty {
                        Button("清除修复点 (\(model.healSpots.count))") {
                            model.healSpots.removeAll()
                        }
                    }

                    Slider(value: $model.params.densityGamma, in: 0.5...2.0, step: 0.01) {
                        Text("反差 (gamma)")
                    }
                    Text(String(format: "%.2f", model.params.densityGamma))
                        .font(.caption).foregroundStyle(.secondary)

                    Slider(value: $model.params.densityDMax, in: 1.0...4.0, step: 0.01) {
                        Text("最大密度 (dmax)")
                    }
                    Text(String(format: "%.2f", model.params.densityDMax))
                        .font(.caption).foregroundStyle(.secondary)
                    Text("dmax 会在打开图片时自动估算，滑杆可手动微调")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("白平衡（密度增益）") {
                    Slider(value: gainBinding(0), in: -1.0...1.0, step: 0.001) {
                        Text("R 增益")
                    }
                    Slider(value: gainBinding(1), in: -1.0...1.0, step: 0.001) {
                        Text("G 增益")
                    }
                    Slider(value: gainBinding(2), in: -1.0...1.0, step: 0.001) {
                        Text("B 增益")
                    }
                }

                Section("曲线") {
                    CurvesEditor(curves: $model.params.curves)
                }

                Section("输出") {
                    HistogramView(histogram: model.histogram)
                        .frame(height: 80)

                    Slider(value: $model.params.screenGlare, in: 0...5, step: 0.1) {
                        Text("眩光补偿 %")
                    }
                    Button("导出 TIFF") { model.export() }
                        .disabled(model.outputImage == nil)
                    Button("批量处理…") { showBatch = true }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("调节")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("打开底片…") { model.open() }
                }
            }
        } detail: {
            // Detail: before / after
            HStack(spacing: 0) {
                if cropping, let img = model.inputImage {
                    CropEditor(image: img, rect: $model.cropRect) {
                        cropping = false
                    }
                } else {
                    imagePanel(title: "底片", image: model.inputImage)
                }
                Divider()
                if healing, let img = model.outputImage {
                    HealEditor(image: img, spots: $model.healSpots,
                               radius: $model.healRadius) {
                        healing = false
                    }
                } else {
                    imagePanel(title: "正片", image: model.outputImage)
                }
            }
        }
        .onChange(of: model.params.densityGamma) { _, _ in model.render() }
        .onChange(of: model.params.densityDMax) { _, _ in model.render() }
        .onChange(of: model.params.rgbGains.0) { _, _ in model.render() }
        .onChange(of: model.params.rgbGains.1) { _, _ in model.render() }
        .onChange(of: model.params.rgbGains.2) { _, _ in model.render() }
        .onChange(of: model.params.screenGlare) { _, _ in model.render() }
        .onChange(of: model.params.curves) { _, _ in model.render() }
        .onChange(of: model.cropRect) { _, _ in model.autoAdjust() }
        .onChange(of: model.healSpots) { _, _ in model.render() }
        .onChange(of: model.healRadius) { _, _ in model.render() }
        .sheet(isPresented: $showBatch) {
            BatchView(model: model)
                .frame(minWidth: 560, minHeight: 420)
        }
    }

    private func gainBinding(_ ch: Int) -> Binding<Float> {
        Binding(
            get: {
                switch ch {
                case 0: return model.params.rgbGains.0
                case 1: return model.params.rgbGains.1
                default: return model.params.rgbGains.2
                }
            },
            set: {
                var g = model.params.rgbGains
                switch ch {
                case 0: g.0 = $0
                case 1: g.1 = $0
                default: g.2 = $0
                }
                model.params.rgbGains = g
                model.params.useGains = true
            }
        )
    }

    @ViewBuilder
    private func imagePanel(title: String, image: NSImage?) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.headline)
            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Rectangle()
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .overlay(Text("拖入或打开一张底片扫描图").foregroundStyle(.secondary))
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Model

final class NegModel: ObservableObject {
    @Published var params = NegParameters()
    @Published var inputImage: NSImage?
    @Published var outputImage: NSImage?
    @Published var histogram: [[Float]] = [[], [], []]

    private var linearPixels: [Float] = []
    private var width = 0
    private var height = 0
    private var wb: (Float, Float, Float) = (1, 1, 1)
    private var autoDMaxValue: Float = 2.2

    var hasImage: Bool { !linearPixels.isEmpty }
    @Published var selectedProfile: FilmProfile = FilmProfiles.all[0]
    /// Crop rect in unit coordinates (0-1), nil = full frame.
    @Published var cropRect: CGRect?
    /// Dust heal spots in unit coordinates.
    @Published var healSpots: [CGPoint] = []
    @Published var healRadius: Float = 4

    /// Working context renders in linear sRGB, so the float bitmap
    /// we get out is linear light — exactly what the pipeline expects.
    private let ciContext = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!
    ])

    init() {
        params.useGains = true
    }

    func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.tiff, .png, .jpeg, .rawImage]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url: url)
    }

    func load(url: URL) {
        inputImage = nil
        outputImage = nil
        // RAW files (NEF/CR3/ARW/...) go through CIRAWFilter for a
        // linear, unsharpened decode; everything else via CGImage.
        let ci: CIImage
        if let rawFilter = CIFilter(imageURL: url, options: nil) {
            rawFilter.setValue(0, forKey: "inputEnableSharpening")
            rawFilter.setValue(0, forKey: "inputEnableNoiseTracking")
            rawFilter.setValue(0, forKey: "inputEnableVendorLensCorrection")
            guard let rawOut = rawFilter.outputImage else { return }
            ci = rawOut
        } else {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
            ci = CIImage(cgImage: cg)
            inputImage = NSImage(cgImage: cg, size: .zero)
        }
        width = Int(ci.extent.width)
        height = Int(ci.extent.height)
        guard width > 0, height > 0 else { return }

        // Decode to linear float RGBA. Rendering through the linear working
        // space yields linear-light floats, exactly what the pipeline expects.
        var pixels = [Float](repeating: 0, count: width * height * 4)
        ciContext.render(ci,
                         toBitmap: &pixels,
                         rowBytes: width * 4 * MemoryLayout<Float>.size,
                         bounds: CGRect(x: 0, y: 0, width: width, height: height),
                         format: .RGBAf,
                         colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB))

        linearPixels = pixels
        wb = (1, 1, 1)
        if inputImage == nil {
            // RAW path: make a quick sRGB preview for the "before" panel.
            let preview = ciContext.createCGImage(ci, from: ci.extent)
            if let preview {
                inputImage = NSImage(cgImage: preview, size: .zero)
            }
        }
        autoAdjust()
    }

    private let renderQueue = DispatchQueue(label: "negclone.render", qos: .userInitiated)
    private var renderTicket = 0

    /// Heavy pipeline work runs off the main thread; stale renders
    /// (from rapid slider drags) are dropped.
    func render() {
        guard !linearPixels.isEmpty else { return }
        renderTicket += 1
        let ticket = renderTicket
        var pixels = linearPixels
        var w = width, h = height
        if let cr = cropRect {
            let (cp, cw, ch) = NegPipeline.cropPixels(pixels, width: w, height: h, rect: cr)
            pixels = cp; w = cw; h = ch
        }
        let wbNow = wb
        let paramsNow = params
        let healSpotsNow = healSpots
        let healRadiusNow = healRadius
        renderQueue.async { [weak self] in
            var wbPixels = pixels
            NegPipeline.applyWB(&wbPixels, wb: wbNow)
            let out = NegPipeline.process(pixels: wbPixels,
                                          width: w, height: h,
                                          params: paramsNow)
            // sRGB encode for display, then per-channel curves
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            let curvesNow = paramsNow.curves
            for i in 0..<(w * h) {
                var r = NegPipeline.srgbEncode(out[i * 4])
                var g = NegPipeline.srgbEncode(out[i * 4 + 1])
                var b = NegPipeline.srgbEncode(out[i * 4 + 2])
                (r, g, b) = NegPipeline.applyCurves(r: r, g: g, b: b, curves: curvesNow)
                bytes[i * 4]     = UInt8(min(1, max(0, r)) * 255)
                bytes[i * 4 + 1] = UInt8(min(1, max(0, g)) * 255)
                bytes[i * 4 + 2] = UInt8(min(1, max(0, b)) * 255)
                bytes[i * 4 + 3] = 255
            }
            // dust healing
            if !healSpotsNow.isEmpty {
                NegPipeline.healSpots(&bytes, width: w, height: h,
                                      spots: healSpotsNow,
                                      radius: Int(healRadiusNow))
            }
            guard let provider = CGDataProvider(data: Data(bytes) as CFData),
                  let cg = CGImage(width: w, height: h,
                                   bitsPerComponent: 8, bitsPerPixel: 32,
                                   bytesPerRow: w * 4,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                   provider: provider, decode: nil,
                                   shouldInterpolate: false, intent: .defaultIntent) else { return }
            let img = NSImage(cgImage: cg, size: .zero)
            // histogram from display bytes
            var hist = [[Float]](repeating: [Float](repeating: 0, count: 256), count: 3)
            for i in 0..<(w * h) {
                hist[0][Int(bytes[i*4])] += 1
                hist[1][Int(bytes[i*4+1])] += 1
                hist[2][Int(bytes[i*4+2])] += 1
            }
            let peak = max(hist[0].max() ?? 1, hist[1].max() ?? 1, hist[2].max() ?? 1)
            for c in 0..<3 { for b in 0..<256 { hist[c][b] /= peak } }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.renderTicket == ticket else { return }
                self.outputImage = img
                self.histogram = hist
            }
        }
    }

    /// Full auto: film-base white balance (if a plausible border is found)
    /// + median-ratio refinement + automatic dmax. Runs on load and from
    /// the "自动调整" button; sliders remain for manual fine-tuning.
    func autoAdjust() {
        guard !linearPixels.isEmpty else { return }

        // 1. white balance from film base, only if it looks like one.
        let x0 = width / 40, x1 = width / 15
        let y0 = height / 3, y1 = 2 * height / 3
        let base = NegPipeline.sampleFilmBase(pixels: linearPixels, width: width, height: height,
                                              region: (x0, x1, y0, y1))
        var wbNow: (Float, Float, Float) = (1, 1, 1)
        if NegPipeline.looksLikeFilmBase(base) {
            wbNow = NegPipeline.baseWBMultipliers(base: base)

            // 2. refine on a small copy.
            let s = max(1, width / 600)
            let sw = width / s, sh = height / s
            var small = [Float](repeating: 0, count: sw * sh * 4)
            for y in 0..<sh {
                for x in 0..<sw {
                    let src = ((y * s) * width + x * s) * 4
                    let dst = (y * sw + x) * 4
                    small[dst] = linearPixels[src] * wbNow.0
                    small[dst + 1] = linearPixels[src + 1] * wbNow.1
                    small[dst + 2] = linearPixels[src + 2] * wbNow.2
                    small[dst + 3] = 1
                }
            }
            let first = NegPipeline.process(pixels: small, width: sw, height: sh, params: params)
            wbNow = NegPipeline.refineWB(positive: first, wb: wbNow)
        }
        wb = wbNow

        // 3. automatic dmax from the white-balanced densities
        //    (on the cropped area if a crop is set).
        var dmaxPixels = linearPixels
        var dw = width, dh = height
        if let cr = cropRect {
            let (cp, cw, ch) = NegPipeline.cropPixels(linearPixels, width: width, height: height, rect: cr)
            dmaxPixels = cp; dw = cw; dh = ch
        }
        autoDMaxValue = NegPipeline.autoDMax(pixels: dmaxPixels, width: dw, height: dh,
                                             gamma: params.densityGamma, wb: wbNow)
        applyProfile(selectedProfile, keepDMax: true)
        render()
    }

    func applyProfile(_ profile: FilmProfile, keepDMax: Bool = false) {
        selectedProfile = profile
        let baseDMax = keepDMax ? autoDMaxValue : params.densityDMax
        // reset to neutral, then apply profile deltas (no accumulation)
        params.densityGamma = 1.0
        params.useMatrix = true
        params.matrix = (1.0197, 0.0317, 0.0091,
                         -0.0052, 0.8933, 0.0521,
                         0.0131, -0.0011, 0.9712)
        FilmProfiles.apply(profile, to: &params)
        // profile dmax is an offset on top of auto
        params.densityDMax = baseDMax + profile.dmaxOffset
        render()
    }

    func export() {
        guard let img = outputImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .tiff, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.tiff]
        panel.nameFieldStringValue = "negtrans-output.tiff"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }

    // MARK: - Batch

    /// Convert a single file with current settings (auto WB + auto dmax +
    /// selected profile) and write a 16-bit TIFF to the output folder.
    /// Runs synchronously; call off the main thread.
    func convertFile(_ url: URL, to outputDir: URL) throws {
        // decode
        let ci: CIImage
        if let rawFilter = CIFilter(imageURL: url, options: nil),
           let rawOut = rawFilter.outputImage {
            rawFilter.setValue(0, forKey: "inputEnableSharpening")
            rawFilter.setValue(0, forKey: "inputEnableNoiseTracking")
            rawFilter.setValue(0, forKey: "inputEnableVendorLensCorrection")
            ci = rawOut
        } else {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                throw BatchError.decodeFailed(url.lastPathComponent)
            }
            ci = CIImage(cgImage: cg)
        }
        let w = Int(ci.extent.width), h = Int(ci.extent.height)
        guard w > 0, h > 0 else { throw BatchError.decodeFailed(url.lastPathComponent) }
        var pixels = [Float](repeating: 0, count: w * h * 4)
        ciContext.render(ci, toBitmap: &pixels,
                         rowBytes: w * 4 * MemoryLayout<Float>.size,
                         bounds: CGRect(x: 0, y: 0, width: w, height: h),
                         format: .RGBAf,
                         colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB))

        // auto WB
        var wbNow: (Float, Float, Float) = (1, 1, 1)
        let base = NegPipeline.sampleFilmBase(pixels: pixels, width: w, height: h,
                                              region: (w/40, w/15, h/3, 2*h/3))
        if NegPipeline.looksLikeFilmBase(base) {
            wbNow = NegPipeline.baseWBMultipliers(base: base)
            let s = max(1, w / 600)
            let sw = w / s, sh = h / s
            var small = [Float](repeating: 0, count: sw * sh * 4)
            for y in 0..<sh {
                for x in 0..<sw {
                    let src = ((y * s) * w + x * s) * 4
                    let dst = (y * sw + x) * 4
                    small[dst] = pixels[src] * wbNow.0
                    small[dst + 1] = pixels[src + 1] * wbNow.1
                    small[dst + 2] = pixels[src + 2] * wbNow.2
                    small[dst + 3] = 1
                }
            }
            let first = NegPipeline.process(pixels: small, width: sw, height: sh, params: params)
            wbNow = NegPipeline.refineWB(positive: first, wb: wbNow)
        }

        // convert (pixels already WB'd, so dmax uses identity wb)
        NegPipeline.applyWB(&pixels, wb: wbNow)
        var pp = params
        pp.densityDMax = NegPipeline.autoDMax(pixels: pixels, width: w, height: h,
                                             gamma: pp.densityGamma, wb: (1, 1, 1))
        let out = NegPipeline.process(pixels: pixels, width: w, height: h, params: pp)

        // 16-bit TIFF (sRGB + curves)
        var u16 = [UInt16](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            var r = NegPipeline.srgbEncode(out[i*4])
            var g = NegPipeline.srgbEncode(out[i*4+1])
            var b = NegPipeline.srgbEncode(out[i*4+2])
            (r, g, b) = NegPipeline.applyCurves(r: r, g: g, b: b, curves: pp.curves)
            u16[i*4]   = UInt16(min(1, max(0, r)) * 65535)
            u16[i*4+1] = UInt16(min(1, max(0, g)) * 65535)
            u16[i*4+2] = UInt16(min(1, max(0, b)) * 65535)
            u16[i*4+3] = 65535
        }
        let provider = CGDataProvider(data: Data(bytes: u16,
                                                 count: u16.count * 2) as CFData)!
        guard let cg = CGImage(width: w, height: h,
                               bitsPerComponent: 16, bitsPerPixel: 64,
                               bytesPerRow: w * 8,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                               provider: provider, decode: nil,
                               shouldInterpolate: false, intent: .defaultIntent) else {
            throw BatchError.encodeFailed(url.lastPathComponent)
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let tiff = rep.representation(using: .tiff, properties: [:]) else {
            throw BatchError.encodeFailed(url.lastPathComponent)
        }
        let outName = url.deletingPathExtension().lastPathComponent + "_negtrans.tiff"
        try tiff.write(to: outputDir.appendingPathComponent(outName))
    }
}

enum BatchError: Error, LocalizedError {
    case decodeFailed(String)
    case encodeFailed(String)
    var errorDescription: String? {
        switch self {
        case .decodeFailed(let n): return "解码失败: \(n)"
        case .encodeFailed(let n): return "编码失败: \(n)"
        }
    }
}

// MARK: - Curves editor

struct CurvesEditor: View {
    @Binding var curves: [[Float]]  // 3 x 5
    @State private var channel = 0  // 0=R, 1=G, 2=B, 3=All
    private let channelNames = ["R", "G", "B", "全部"]
    private let channelColors: [Color] = [.red, .green, .blue, .white]

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                ForEach(0..<4) { i in
                    Button(channelNames[i]) { channel = i }
                        .buttonStyle(.bordered)
                        .tint(channel == i ? channelColors[i] : nil)
                }
                Spacer()
                Button("重置") { reset() }
                    .font(.caption)
            }
            .font(.caption)

            GeometryReader { geo in
                let size = geo.size
                ZStack {
                    // grid
                    Path { p in
                        for i in 0...4 {
                            let x = size.width * CGFloat(i) / 4
                            p.move(to: CGPoint(x: x, y: 0))
                            p.addLine(to: CGPoint(x: x, y: size.height))
                            let y = size.height * CGFloat(i) / 4
                            p.move(to: CGPoint(x: 0, y: y))
                            p.addLine(to: CGPoint(x: size.width, y: y))
                        }
                    }
                    .stroke(Color.gray.opacity(0.3), lineWidth: 0.5)
                    // curves
                    ForEach(0..<3) { c in
                        if channel == 3 || channel == c {
                            curvePath(c, size: size)
                                .stroke(channelColors[c], lineWidth: channel == c ? 2 : 1)
                        }
                    }
                    // points
                    ForEach(0..<5) { i in
                        if channel < 3 {
                            let x = size.width * CGFloat(i) / 4
                            let y = size.height * (1 - CGFloat(curves[channel][i]))
                            Circle()
                                .fill(channelColors[channel])
                                .frame(width: 10, height: 10)
                                .position(x: x, y: y)
                                .gesture(
                                    DragGesture()
                                        .onChanged { v in
                                            let yVal = 1 - Float(v.location.y / size.height)
                                            setPoint(channel: channel, index: i,
                                                     value: min(1, max(0, yVal)))
                                        }
                                )
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .frame(height: 160)
            .background(Color.black.opacity(0.2))
            .cornerRadius(4)
        }
        .padding(8)
    }

    private func curvePath(_ c: Int, size: CGSize) -> Path {
        var path = Path()
        let pts = curves[c]
        for i in 0..<5 {
            let x = size.width * CGFloat(i) / 4
            let y = size.height * (1 - CGFloat(pts[i]))
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }

    private func setPoint(channel: Int, index: Int, value: Float) {
        if channel == 3 {
            for c in 0..<3 { curves[c][index] = value }
        } else {
            curves[channel][index] = value
        }
    }

    private func reset() {
        curves = [[0, 0.25, 0.5, 0.75, 1] as [Float],
                  [0, 0.25, 0.5, 0.75, 1] as [Float],
                  [0, 0.25, 0.5, 0.75, 1] as [Float]]
    }
}

// MARK: - Heal editor

struct HealEditor: View {
    let image: NSImage
    @Binding var spots: [CGPoint]  // unit coords
    @Binding var radius: Float
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Text("灰尘修复").font(.headline)
            Text("点击灰尘点进行修复")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("半径")
                    .font(.caption)
                Slider(value: $radius, in: 2...20, step: 1)
                    .frame(width: 120)
                Text("\(Int(radius))")
                    .font(.caption)
                    .frame(width: 24)
                Spacer()
                Button("清除全部") { spots.removeAll() }
                    .font(.caption)
                Button("完成", action: onDone)
                    .font(.caption)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 8)

            GeometryReader { geo in
                let imgSize = image.size
                let scale = min(geo.size.width / imgSize.width,
                                geo.size.height / imgSize.height)
                let dw = imgSize.width * scale, dh = imgSize.height * scale
                let ox = (geo.size.width - dw) / 2, oy = (geo.size.height - dh) / 2

                ZStack {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width, height: geo.size.height)
                    // spots
                    ForEach(spots.indices, id: \.self) { i in
                        let s = spots[i]
                        Circle()
                            .stroke(Color.red, lineWidth: 1.5)
                            .frame(width: CGFloat(radius) * 2 * scale,
                                   height: CGFloat(radius) * 2 * scale)
                            .position(x: ox + s.x * dw, y: oy + s.y * dh)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { loc in
                    let ux = (loc.x - ox) / dw
                    let uy = (loc.y - oy) / dh
                    if ux >= 0 && ux <= 1 && uy >= 0 && uy <= 1 {
                        spots.append(CGPoint(x: ux, y: uy))
                    }
                }
            }
        }
        .padding(8)
    }
}

// MARK: - Histogram

struct HistogramView: View {
    let histogram: [[Float]]  // 3 x 256, normalized
    private let colors: [Color] = [.red, .green, .blue]

    var body: some View {
        Canvas { ctx, size in
            guard histogram.count == 3, !histogram[0].isEmpty else { return }
            let w = size.width / 256
            for c in 0..<3 {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height))
                for b in 0..<256 {
                    let x = CGFloat(b) * w
                    let y = size.height - CGFloat(histogram[c][b]) * size.height
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()
                ctx.fill(path, with: .color(colors[c].opacity(0.45)))
            }
        }
    }
}

// MARK: - Crop editor

struct CropEditor: View {
    let image: NSImage
    @Binding var rect: CGRect?  // unit 0-1, nil = full
    var onDone: () -> Void

    @State private var aspect: CGFloat? = nil
    @State private var dragStart: CGPoint? = nil
    @State private var dragCurrent: CGPoint? = nil

    private let aspects: [(String, CGFloat?)] = [
        ("自由", nil), ("3:2", 1.5), ("4:3", 4/3), ("1:1", 1), ("6:7", 6/7), ("4:5", 0.8),
    ]

    var body: some View {
        VStack(spacing: 6) {
            Text("裁切").font(.headline)
            HStack {
                ForEach(aspects, id: \.0) { name, a in
                    Button(name) { aspect = a }
                        .buttonStyle(.bordered)
                        .tint(aspect == a ? .accentColor : nil)
                }
                Spacer()
                Button("重置") { rect = nil }
                Button("完成", action: onDone).keyboardShortcut(.defaultAction)
            }
            .font(.caption)
            .padding(.horizontal, 8)

            GeometryReader { geo in
                let imgSize = image.size
                // fit image into geo
                let scale = min(geo.size.width / imgSize.width,
                                geo.size.height / imgSize.height)
                let dw = imgSize.width * scale, dh = imgSize.height * scale
                let ox = (geo.size.width - dw) / 2, oy = (geo.size.height - dh) / 2

                ZStack {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width, height: geo.size.height)
                    // dim outside
                    CropDimView(rect: currentRect(geo: geo, ox: ox, oy: oy, dw: dw, dh: dh),
                                full: CGRect(x: ox, y: oy, width: dw, height: dh))
                    // rect outline
                    if let r = currentRect(geo: geo, ox: ox, oy: oy, dw: dw, dh: dh) {
                        Rectangle()
                            .stroke(Color.accentColor, lineWidth: 2)
                            .frame(width: r.width, height: r.height)
                            .position(x: r.midX, y: r.midY)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { v in
                            if dragStart == nil { dragStart = v.startLocation }
                            dragCurrent = v.location
                        }
                        .onEnded { v in
                            if let s = dragStart {
                                let r = makeRect(from: s, to: v.location,
                                                 ox: ox, oy: oy, dw: dw, dh: dh)
                                rect = r
                            }
                            dragStart = nil; dragCurrent = nil
                        }
                )
            }
        }
        .padding(8)
    }

    private func currentRect(geo: GeometryProxy, ox: CGFloat, oy: CGFloat,
                             dw: CGFloat, dh: CGFloat) -> CGRect? {
        if let s = dragStart, let c = dragCurrent {
            let r = makeRect(from: s, to: c, ox: ox, oy: oy, dw: dw, dh: dh)
            return CGRect(x: ox + r.minX * dw, y: oy + r.minY * dh,
                          width: r.width * dw, height: r.height * dh)
        }
        if let r = rect {
            return CGRect(x: ox + r.minX * dw, y: oy + r.minY * dh,
                          width: r.width * dw, height: r.height * dh)
        }
        return nil
    }

    private func makeRect(from s: CGPoint, to e: CGPoint,
                          ox: CGFloat, oy: CGFloat, dw: CGFloat, dh: CGFloat) -> CGRect {
        // to unit coords, clamped to image
        var x0 = min(max((s.x - ox) / dw, 0), 1)
        var y0 = min(max((s.y - oy) / dh, 0), 1)
        var x1 = min(max((e.x - ox) / dw, 0), 1)
        var y1 = min(max((e.y - oy) / dh, 0), 1)
        if let a = aspect {
            // constrain by width, adjust height
            var w = abs(x1 - x0)
            var h = w / a
            if h > 1 { h = 1; w = h * a }
            x1 = x0 + (e.x >= s.x ? w : -w)
            y1 = y0 + (e.y >= s.y ? h : -h)
            x0 = min(max(x0, 0), 1); x1 = min(max(x1, 0), 1)
            y0 = min(max(y0, 0), 1); y1 = min(max(y1, 0), 1)
        }
        return CGRect(x: min(x0, x1), y: min(y0, y1),
                      width: abs(x1 - x0), height: abs(y1 - y0))
    }
}

struct CropDimView: View {
    let rect: CGRect?  // in view coords, nil = no dim
    let full: CGRect
    var body: some View {
        Canvas { ctx, size in
            guard let r = rect else { return }
            // draw 4 dim rects around r
            ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: r.minY)),
                     with: .color(.black.opacity(0.55)))
            ctx.fill(Path(CGRect(x: 0, y: r.maxY, width: size.width, height: size.height - r.maxY)),
                     with: .color(.black.opacity(0.55)))
            ctx.fill(Path(CGRect(x: 0, y: r.minY, width: r.minX, height: r.height)),
                     with: .color(.black.opacity(0.55)))
            ctx.fill(Path(CGRect(x: r.maxX, y: r.minY, width: size.width - r.maxX, height: r.height)),
                     with: .color(.black.opacity(0.55)))
        }
    }
}

// MARK: - Batch UI

struct BatchItem: Identifiable {
    let id = UUID()
    let url: URL
    var status: String = "等待"
}

struct BatchView: View {
    @ObservedObject var model: NegModel
    @State private var items: [BatchItem] = []
    @State private var outputDir: URL?
    @State private var running = false
    @State private var progress: Double = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text("批量处理").font(.headline)
            Text("使用当前胶片预设与参数自动转换（自动白平衡 + 自动 dmax），输出 16-bit TIFF。")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Button("添加文件…") { pickFiles() }
                Button("选择输出文件夹…") { pickOutput() }
                Spacer()
                if let dir = outputDir {
                    Text(dir.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                }
            }

            List(items) { item in
                HStack {
                    Text(item.url.lastPathComponent).font(.caption)
                    Spacer()
                    Text(item.status).font(.caption).foregroundStyle(.secondary)
                }
            }

            if running {
                ProgressView(value: progress, total: 1)
            }

            HStack {
                Spacer()
                Button("关闭") { dismiss() }.disabled(running)
                Button("开始转换") { run() }
                    .disabled(running || items.isEmpty || outputDir == nil)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.tiff, .png, .jpeg, .rawImage]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !items.contains(where: { $0.url == url }) {
            items.append(BatchItem(url: url))
        }
    }

    private func pickOutput() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        outputDir = url
    }

    private func run() {
        guard let outDir = outputDir, !running else { return }
        running = true
        progress = 0
        let params = model.params
        DispatchQueue.global(qos: .userInitiated).async {
            // snapshot settings on a scratch model so UI stays interactive
            let worker = NegModel()
            worker.params = params
            for idx in items.indices {
                let url = items[idx].url
                DispatchQueue.main.async { items[idx].status = "处理中…" }
                do {
                    try worker.convertFile(url, to: outDir)
                    DispatchQueue.main.async { items[idx].status = "完成" }
                } catch {
                    DispatchQueue.main.async { items[idx].status = "失败" }
                }
                DispatchQueue.main.async {
                    progress = Double(idx + 1) / Double(items.count)
                }
            }
            DispatchQueue.main.async { running = false }
        }
    }
}
