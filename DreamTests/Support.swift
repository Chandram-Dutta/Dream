import Foundation
import simd
@testable import Dream

// Small helpers the checks share. The tests run in the app on an iPhone or Simulator (Xcode's
// DreamTests target), and on this Mac with Tools/tests.sh, so nothing here may need either one.

func near(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6) -> Bool { abs(a - b) <= tolerance }

func near(_ a: Double?, _ b: Double, within tolerance: Double = 1e-6) -> Bool { a.map { abs($0 - b) <= tolerance } ?? false }

func near(_ a: Vec3, _ b: Vec3, _ tolerance: Double = 1e-6) -> Bool { simd_length(a - b) <= tolerance }

/// An adjustable number input, as figures and scenes use them.
func input(_ name: String, _ initial: Double, _ min: Double, _ max: Double, step: Double = 0.1, role: InputRole = .adjustable) -> Input {
    Input(name: name, label: name, format: .number, initial: initial, min: min, max: max, step: step, options: [], role: role)
}

/// Whether timings mean anything: unoptimized builds, like Xcode's Debug, are many times slower
/// than the app people run. Tools/tests.sh builds with the optimizer on.
var isOptimized: Bool { !_isDebugAssertConfiguration() }
