import Foundation

/// Converts scroll distance to a multiplicative zoom. The result depends on total distance,
/// not on how the OS splits/coalesces events. Only the viewport range limits the result.
enum ScrollZoom {
    // One wheel unit or 20 high-resolution pixels changes the map scale by 20%.
    static let wheelSensitivity = log(1.2)
    static let pixelsPerWheelUnit = 20.0

    static func radius(from radius: Double, delta: Double, precise: Bool,
                       range: ClosedRange<Double>) -> Double? {
        guard radius.isFinite, radius > 0, delta.isFinite, delta != 0 else { return nil }
        let current = min(max(radius, range.lowerBound), range.upperBound)
        let step = delta * (precise ? wheelSensitivity / pixelsPerWheelUnit : wheelSensitivity)
        // Compare in log space before exp, so even extreme finite deltas cannot overflow.
        if step >= log(current / range.lowerBound) { return range.lowerBound }
        if step <= log(current / range.upperBound) { return range.upperBound }
        return current * exp(-step)
    }
}
