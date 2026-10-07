import Foundation
func timestamp(_ pts: Double, previous: UInt32) -> UInt32 {
    let ticks = pts * 90_000.0
    guard pts >= 0, ticks.isFinite else { return previous &+ 1 }
    return UInt32(ticks.rounded(.down).truncatingRemainder(dividingBy: 4_294_967_296.0))
}
assert(timestamp(0, previous: 0) == 0)
assert(timestamp(1, previous: 0) == 90_000)
assert(timestamp(4294967296.0 / 90000.0, previous: UInt32.max) == 0)
assert(timestamp(86400, previous: 0) == 3481032704)
assert(timestamp(.nan, previous: 4) == 5)
assert(timestamp(.infinity, previous: UInt32.max) == 0)
assert(timestamp(-1, previous: 4) == 5)
assert(timestamp(Double.greatestFiniteMagnitude, previous: 4) == 5)
print("Timestamp checks passed: normal values, 32-bit rollover, one-day timestamp, and invalid input.")
