import Foundation

// Byte-level decoding of drive health data, shared by the direct build's DiskMonitor and
// Blip Helper (which reads it on the App Store build's behalf). The IOKit plug-in calls
// that fill the buffers stay with their owners; the parsing lives here so it can be
// checked against fixture buffers.

/// Parsed fields from the NVMe SMART/Health Information log (log page 0x02, 512 bytes,
/// little-endian multi-byte fields).
struct NVMeSMARTLog: Equatable, Sendable {
    var criticalWarning: UInt8
    var temperatureKelvin: UInt16
    var availableSpare: UInt8
    var spareThreshold: UInt8
    var percentUsed: UInt8
    var dataUnitsRead: UInt64
    var dataUnitsWritten: UInt64
    var powerCycles: UInt64
    var powerOnHours: UInt64
    var unsafeShutdowns: UInt64
    var mediaErrors: UInt64

    /// The highest byte offset read (media errors: 160 + 8).
    static let minimumLength = 168

    /// Decodes the log page; nil when the buffer is too short to hold it.
    init?(bytes: [UInt8]) {
        guard bytes.count >= Self.minimumLength else { return nil }
        func u64(_ off: Int) -> UInt64 {
            (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[off + $1]) << (8 * UInt64($1)) }
        }
        criticalWarning = bytes[0]
        temperatureKelvin = UInt16(bytes[1]) | UInt16(bytes[2]) << 8
        availableSpare = bytes[3]
        spareThreshold = bytes[4]
        percentUsed = bytes[5]
        dataUnitsRead = u64(32)
        dataUnitsWritten = u64(48)
        powerCycles = u64(112)
        powerOnHours = u64(128)
        unsafeShutdowns = u64(144)
        mediaErrors = u64(160)
    }

    /// Composite temperature in °C (the log reports Kelvin).
    var temperatureCelsius: Int { Int(temperatureKelvin) - 273 }

    /// "Verified" when no critical-warning bit is set, else "Failing".
    var smartStatus: String { criticalWarning == 0 ? "Verified" : "Failing" }
}

/// Best-effort reading of the ATA S.M.A.R.T. attribute table (offset 2, 30 entries of
/// 12 bytes). Only plausible values are trusted — USB bridges differ in what (and how)
/// they report, so anything odd simply yields nil.
enum ATASMARTAttributes {
    /// Attribute IDs vendors use for "life remaining" / wear level (normalized value).
    static let lifeIDs: Set<UInt8> = [231, 233, 202, 169, 177, 173]

    static func parse(_ buffer: [UInt8]) -> (life: Int?, tempC: Int?, powerOnHours: UInt64?) {
        var life: Int?
        var tempC: Int?
        var poh: UInt64?
        for i in 0..<30 {
            let off = 2 + i * 12
            guard off + 11 < buffer.count else { break }
            let id = buffer[off]
            guard id != 0, id != 0xFF else { continue }
            let current = Int(buffer[off + 3])
            if lifeIDs.contains(id), current >= 1, current <= 100, life == nil {
                life = current
            }
            if id == 194 {  // temperature — normalized current value is °C on most SSDs
                if current > 0, current < 120 { tempC = current }
            }
            if id == 9 {    // power-on hours — 48-bit raw value, little-endian
                var h: UInt64 = 0
                for b in 0..<6 { h |= UInt64(buffer[off + 5 + b]) << (8 * b) }
                if h > 0, h < 1_000_000 { poh = h }
            }
        }
        return (life, tempC, poh)
    }
}
