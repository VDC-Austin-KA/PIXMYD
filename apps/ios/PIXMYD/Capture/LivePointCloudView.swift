import Metal
import MetalKit
import SwiftUI
import simd

/// Live LiDAR point cloud drawn over the viewfinder.
///
/// This is the "Live Preview" affordance: raw depth, rendered as it arrives, so
/// the user can see coverage while they still have the chance to fix it. It is
/// explicitly *not* the reconstruction — it is unfused, unfiltered, and
/// discarded every frame. Presenting it as a result would set an expectation
/// the deliverable cannot meet, so it renders as translucent points rather than
/// as a surface.
struct LivePointCloudView: UIViewRepresentable {
    let points: [SIMD3<Float>]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.isOpaque = false
        view.backgroundColor = .clear
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.preferredFramesPerSecond = 30
        view.delegate = context.coordinator
        context.coordinator.configure(view: view)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.update(points: points)
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        private var device: MTLDevice?
        private var queue: MTLCommandQueue?
        private var pipeline: MTLRenderPipelineState?
        private var vertexBuffer: MTLBuffer?
        private var pointCount = 0
        /// Set by the AR controller each frame; identity until then.
        var viewProjection = matrix_identity_float4x4

        func configure(view: MTKView) {
            guard let device = view.device else { return }
            self.device = device
            queue = device.makeCommandQueue()

            guard let library = try? device.makeLibrary(source: Self.shaderSource, options: nil)
            else { return }

            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "point_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "point_fragment")
            descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
            // Additive-over-alpha so overlapping points read as density rather
            // than saturating to a flat sheet.
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].rgbBlendOperation = .add
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat

            pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
        }

        func update(points: [SIMD3<Float>]) {
            guard let device, !points.isEmpty else {
                pointCount = 0
                return
            }
            let length = MemoryLayout<SIMD3<Float>>.stride * points.count
            // Reallocate only when the buffer is too small. The point count
            // fluctuates every frame and a per-frame allocation would show up
            // as a stutter in the viewfinder.
            if vertexBuffer == nil || vertexBuffer!.length < length {
                vertexBuffer = device.makeBuffer(length: max(length, 65536), options: .storageModeShared)
            }
            vertexBuffer?.contents().copyMemory(
                from: points, byteCount: length
            )
            pointCount = points.count
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard pointCount > 0,
                  let pipeline, let queue, let buffer = vertexBuffer,
                  let descriptor = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable,
                  let commands = queue.makeCommandBuffer(),
                  let encoder = commands.makeRenderCommandEncoder(descriptor: descriptor)
            else { return }

            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            var matrix = viewProjection
            encoder.setVertexBytes(&matrix, length: MemoryLayout<simd_float4x4>.size, index: 1)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: pointCount)
            encoder.endEncoding()
            commands.present(drawable)
            commands.commit()
        }

        /// Height ramps blue to warm so the eye reads structure rather than a
        /// flat fog. Colour here is illustrative, not semantic — it carries no
        /// accuracy meaning, which is why it does not use the status palette.
        private static let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct PointOut {
            float4 position [[position]];
            float  size     [[point_size]];
            float4 color;
        };

        vertex PointOut point_vertex(uint vid [[vertex_id]],
                                     constant float3 *points [[buffer(0)]],
                                     constant float4x4 &viewProjection [[buffer(1)]])
        {
            PointOut out;
            float3 p = points[vid];
            out.position = viewProjection * float4(p, 1.0);
            // Nearer points draw larger, so density reads as proximity.
            float w = max(out.position.w, 0.001);
            out.size = clamp(9.0 / w, 2.0, 11.0);

            float h = clamp((p.y + 1.5) / 3.0, 0.0, 1.0);
            out.color = float4(mix(float3(0.25, 0.55, 0.95),
                                   float3(0.98, 0.78, 0.35), h), 0.75);
            return out;
        }

        fragment float4 point_fragment(PointOut in [[stage_in]],
                                       float2 coord [[point_coord]])
        {
            // Round points with a soft edge. Square points alias badly against
            // a camera feed and read as noise.
            float d = length(coord - float2(0.5));
            if (d > 0.5) discard_fragment();
            float alpha = in.color.a * smoothstep(0.5, 0.35, d);
            return float4(in.color.rgb, alpha);
        }
        """
    }
}
