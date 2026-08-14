import AppKit
import Metal
import QuartzCore
import simd

/// The water splash the submarine bursts out of, rendered by a real Metal
/// fragment shader (Runde 11, gewünscht war echtes Shader-Wasser, not drawn
/// shapes). Velocity-stretched metaballs + fine mist, transparent, so only the
/// bright droplets show over the banner and the desktop behind it. The shader is
/// compiled at runtime from source (no Xcode / no prebuilt .metallib needed, so
/// `swift build` on the command line is enough). If Metal is unavailable the
/// view simply renders nothing, the leap still plays, just without spray.
@MainActor
final class SplashMetalView: NSView {
    static let duration: Double = 1.25

    private let origin: SIMD2<Float>   // breakthrough point in this view, uv, y up
    private let amount: Float
    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var metalLayer: CAMetalLayer?
    private var timer: Timer?
    private var startedAt = Date()

    init(frame: NSRect, origin: SIMD2<Float>, amount: Float) {
        self.origin = origin
        self.amount = amount
        super.init(frame: frame)
        wantsLayer = true
        setupMetal()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isOpaque: Bool { false }

    private func setupMetal() {
        guard let dev = MTLCreateSystemDefaultDevice() else { return }
        device = dev
        queue = dev.makeCommandQueue()

        let layer = CAMetalLayer()
        layer.device = dev
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = false
        layer.backgroundColor = NSColor.clear.cgColor
        self.layer = layer
        metalLayer = layer

        do {
            let lib = try dev.makeLibrary(source: Self.shaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = lib.makeFunction(name: "splash_vertex")
            desc.fragmentFunction = lib.makeFunction(name: "splash_fragment")
            if let ca = desc.colorAttachments[0] {
                ca.pixelFormat = .bgra8Unorm
                ca.isBlendingEnabled = true
                ca.rgbBlendOperation = .add
                ca.alphaBlendOperation = .add
                ca.sourceRGBBlendFactor = .one            // colours are premultiplied in the shader
                ca.sourceAlphaBlendFactor = .one
                ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
                ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            pipeline = try dev.makeRenderPipelineState(descriptor: desc)
        } catch {
            NSLog("MeetingBlitz splash shader failed: \(error)")
            pipeline = nil
        }
    }

    func start() {
        guard pipeline != nil else { return }
        startedAt = Date()
        updateDrawableSize()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// Replay from the beginning (used by the `--demo-splash` debug loop).
    func restart() { startedAt = Date() }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2.0
        metalLayer?.contentsScale = scale
        metalLayer?.drawableSize = CGSize(width: max(1, bounds.width * scale),
                                          height: max(1, bounds.height * scale))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSize()
    }

    private func render() {
        guard let layer = metalLayer, let pipeline, let queue,
              let drawable = layer.nextDrawable() else { return }

        var splash = Float(Date().timeIntervalSince(startedAt) / Self.duration)
        var res = SIMD2<Float>(Float(layer.drawableSize.width), Float(layer.drawableSize.height))
        var org = origin
        var amt = amount
        // Fixed reference scale (in drawable px) so the droplets keep the same
        // size/reach no matter how large the panel is, a bigger panel just
        // gives them room to fly instead of clipping at the edge.
        var refScale = Float(340.0 * (layer.contentsScale))

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store

        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&res, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        enc.setFragmentBytes(&splash, length: MemoryLayout<Float>.stride, index: 1)
        enc.setFragmentBytes(&amt, length: MemoryLayout<Float>.stride, index: 2)
        enc.setFragmentBytes(&org, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)
        enc.setFragmentBytes(&refScale, length: MemoryLayout<Float>.stride, index: 4)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    // MARK: - Shader (Metal Shading Language), compiled at runtime

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    vertex float4 splash_vertex(uint vid [[vertex_id]]) {
        float2 p[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
        return float4(p[vid], 0.0, 1.0);
    }

    static inline float h11(float n){ return fract(sin(n * 127.1 + 0.7) * 43758.5453); }

    fragment float4 splash_fragment(float4 pos [[position]],
                                    constant float2 &res      [[buffer(0)]],
                                    constant float  &splash   [[buffer(1)]],
                                    constant float  &amount   [[buffer(2)]],
                                    constant float2 &origin   [[buffer(3)]],
                                    constant float  &refScale [[buffer(4)]]) {
        // Work in a FIXED reference-point space (1.0 = refScale px). The droplet
        // physics is identical regardless of panel size; a larger panel simply
        // shows more of this space, so nothing clips at the edge.
        float2 p = pos.xy / refScale;                 // y DOWN
        float2 org = (origin * res) / refScale;       // burst point (origin is uv)
        float g = 1.5;
        float field = 0.0;
        float mist = 0.0;

        // main droplets: velocity-stretched metaballs (motion blur). Spray UP
        // (negative y in this y-down space) out of the burst point, gravity down.
        for (int i = 0; i < 26; i++) {
            float fi = float(i);
            float a1 = h11(fi), a2 = h11(fi + 7.0), a3 = h11(fi + 19.0);
            float side = (fmod(fi, 2.0) < 1.0) ? 1.0 : -1.0;
            float ang = 1.5708 + side * (0.12 + a1 * 0.95);
            float speed = 0.34 + a2 * 0.62;
            float delay = a1 * 0.12;
            float t = max(0.0, splash - delay);
            if (t <= 0.0) continue;
            float2 vel = float2(cos(ang), -sin(ang)) * speed;   // -sin => up
            float2 pp = org + vel * t;
            pp.y += 0.5 * g * t * t;                            // gravity pulls back down
            float r = (0.006 + a3 * 0.017) * smoothstep(0.0, 0.05, t) * (1.0 - splash * 0.15);
            float2 d = p - pp;
            float2 vn = normalize(vel + float2(0.0, 0.001));
            float al = dot(d, vn);
            float pe = dot(d, float2(-vn.y, vn.x));
            float2 ds = float2(al / (1.0 + speed * 1.5), pe);
            field += r * r / (dot(ds, ds) + 0.00002);
        }

        // fine mist
        for (int j = 0; j < 22; j++) {
            float fj = float(j);
            float m1 = h11(fj + 40.0), m2 = h11(fj + 61.0), m3 = h11(fj + 83.0);
            float ang = 1.5708 + (m1 - 0.5) * 2.7;
            float speed = 0.5 + m2 * 0.8;
            float delay = m3 * 0.16;
            float t = max(0.0, splash - delay);
            if (t <= 0.0) continue;
            float2 vel = float2(cos(ang), -sin(ang)) * speed;
            float2 pp = org + vel * t;
            pp.y += 0.5 * g * t * t;
            float2 d = p - pp;
            mist += (0.0000075 * amount) / (dot(d, d) + 0.00025) * (1.0 - t);
        }

        float a = smoothstep(0.8, 1.2, field);
        float rim = smoothstep(0.95, 1.5, field) - smoothstep(1.5, 2.6, field);
        float3 water = float3(0.88, 0.97, 0.94);
        float3 teal  = float3(0.52, 0.90, 0.82);
        float3 col = mix(teal, water, clamp(rim * 0.9 + 0.45, 0.0, 1.0));
        col += float3(1.0) * rim * 0.35;
        float alpha = clamp(a + rim * 0.4 + clamp(mist, 0.0, 0.65), 0.0, 1.0);
        // Cut the faint panel-wide mist haze to FULLY transparent so no
        // rectangular "box" edge is visible, only real droplets remain.
        alpha = clamp((alpha - 0.10) * 1.35, 0.0, 1.0);
        alpha *= 1.0 - smoothstep(0.7, 1.02, splash);   // fade the whole splash out
        return float4(col * alpha, alpha);              // premultiplied
    }
    """
}
