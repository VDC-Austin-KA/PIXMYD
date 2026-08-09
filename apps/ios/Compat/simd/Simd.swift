// A minimal stand-in for Apple's `simd` module, so the parts of the app that
// are pure arithmetic can be compiled and unit-tested on Linux.
//
// Why this exists: the reconstruction and export code is where the bugs that
// silently ruin a survey live — a flipped axis, a truncated TSDF weight, a PLY
// header that says the wrong count. On Apple platforms that code is only ever
// exercised by running the app on a phone. This shim lets CI compile and test
// it on an ordinary Linux runner, on every push, for free.
//
// It is deliberately *not* a general simd implementation. It covers exactly the
// surface `Exporters`, `TsdfVolume`, `CaptureBundle` and `NmeaAssembler` use,
// and nothing else — a shim that quietly diverges from the real thing would be
// worse than no shim, because the tests would be validating the wrong maths.
// `SIMD3` itself is not redeclared here: it is Swift standard library, not simd,
// and is identical on both platforms.
//
// Never linked into the iOS app. Xcode builds from project.yml and gets the
// real simd; only Package.swift references this target, and only on Linux.

#if os(Linux)

import Foundation

@inlinable
public func simd_length(_ v: SIMD3<Float>) -> Float {
    (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
}

@inlinable
public func simd_distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
    simd_length(a - b)
}

@inlinable
public func simd_normalize(_ v: SIMD3<Float>) -> SIMD3<Float> {
    v / simd_length(v)
}

@inlinable
public func simd_cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3<Float>(
        a.y * b.z - a.z * b.y,
        a.z * b.x - a.x * b.z,
        a.x * b.y - a.y * b.x
    )
}

@inlinable
public func simd_dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
    a.x * b.x + a.y * b.y + a.z * b.z
}

// Generic over scalar type: the exporters take bounds over SIMD3<Double> world
// coordinates and over SIMD3<Float> local ones, and Apple's simd_min/simd_max
// are overloaded for both.
@inlinable
public func simd_min<V: SIMD>(_ a: V, _ b: V) -> V where V.Scalar: Comparable {
    a.replacing(with: b, where: b .< a)
}

@inlinable
public func simd_max<V: SIMD>(_ a: V, _ b: V) -> V where V.Scalar: Comparable {
    a.replacing(with: b, where: b .> a)
}

/// Single-precision quaternion, stored [ix, iy, iz, r] to match Apple's layout.
///
/// `act` uses the Rodrigues form rather than building a rotation matrix:
///
///     v' = v + 2r(q × v) + 2(q × (q × v))
///
/// which is what Apple's implementation does, and matters here because
/// `TsdfVolume.integrate` calls it once per pixel per frame.
public struct simd_quatf: Equatable, Sendable {
    public var vector: SIMD4<Float>

    public init(ix: Float, iy: Float, iz: Float, r: Float) {
        vector = SIMD4<Float>(ix, iy, iz, r)
    }

    public init(angle: Float, axis: SIMD3<Float>) {
        let half = angle / 2
        let s = sin(half)
        let a = simd_normalize(axis)
        vector = SIMD4<Float>(a.x * s, a.y * s, a.z * s, cos(half))
    }

    public var imag: SIMD3<Float> { SIMD3<Float>(vector.x, vector.y, vector.z) }
    public var real: Float { vector.w }

    public func act(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let q = imag
        let t = simd_cross(q, v) * 2
        return v + t * real + simd_cross(q, t)
    }
}

#endif
