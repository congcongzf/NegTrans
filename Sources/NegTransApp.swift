//
//  NegTransApp.swift
//  NegTrans – film negative to positive converter for macOS
//

import SwiftUI
import AppKit
import CoreImage
import UniformTypeIdentifiers

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

    var body: some View {
        NavigationSplitView {
            // Sidebar: controls
            Form {
                Section("底片反转") {
                    Button("自动调整") { model.autoAdjust() }
                        .disabled(!model.hasImage)

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

                Section("输出") {
                    Slider(value: $model.params.screenGlare, in: 0...5, step: 0.1) {
                        Text("眩光补偿 %")
                    }
                    Button("导出 TIFF") { model.export() }
                        .disabled(model.outputImage == nil)
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
                imagePanel(title: "底片", image: model.inputImage)
                Divider()
                imagePanel(title: "正片", image: model.outputImage)
            }
        }
        .onChange(of: model.params.densityGamma) { _, _ in model.render() }
        .onChange(of: model.params.densityDMax) { _, _ in model.render() }
        .onChange(of: model.params.rgbGains.0) { _, _ in model.render() }
        .onChange(of: model.params.rgbGains.1) { _, _ in model.render() }
        .onChange(of: model.params.rgbGains.2) { _, _ in model.render() }
        .onChange(of: model.params.screenGlare) { _, _ in model.render() }
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

    private var linearPixels: [Float] = []
    private var width = 0
    private var height = 0
    private var wb: (Float, Float, Float) = (1, 1, 1)

    var hasImage: Bool { !linearPixels.isEmpty }

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
        let pixels = linearPixels
        let w = width, h = height
        let wbNow = wb
        let paramsNow = params
        renderQueue.async { [weak self] in
            var wbPixels = pixels
            NegPipeline.applyWB(&wbPixels, wb: wbNow)
            let out = NegPipeline.process(pixels: wbPixels,
                                          width: w, height: h,
                                          params: paramsNow)
            // sRGB encode for display
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            for i in 0..<(w * h) {
                bytes[i * 4]     = UInt8(NegPipeline.srgbEncode(out[i * 4]) * 255)
                bytes[i * 4 + 1] = UInt8(NegPipeline.srgbEncode(out[i * 4 + 1]) * 255)
                bytes[i * 4 + 2] = UInt8(NegPipeline.srgbEncode(out[i * 4 + 2]) * 255)
                bytes[i * 4 + 3] = 255
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
            DispatchQueue.main.async { [weak self] in
                guard let self, self.renderTicket == ticket else { return }
                self.outputImage = img
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

        // 3. automatic dmax from the white-balanced densities.
        params.densityDMax = NegPipeline.autoDMax(pixels: linearPixels, width: width, height: height,
                                                  gamma: params.densityGamma, wb: wbNow)
        render()
    }

    func export() {
        guard let img = outputImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .tiff, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.tiff]
        panel.nameFieldStringValue = "negclone-output.tiff"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }
}
