import SwiftUI

struct BatteryDetailPanel: View {
    let stats: BatteryStats

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Battery header
            HStack {
                Image(systemName: batteryIcon)
                    .foregroundStyle(batteryColor)
                Text("Battery")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(Fmt.percent(stats.level))
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
            }

            if stats.isPresent {
                // Battery bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(batteryColor.opacity(0.1))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(batteryColor)
                            .frame(width: geo.size.width * min(stats.level / 100, 1))
                    }
                }
                .frame(height: 8)

                // Details
                VStack(alignment: .leading, spacing: 4) {
                    detailRow("Status", value: stats.isCharging ? "Charging" : "On Battery")
                    detailRow("Source", value: stats.powerSource)
                    detailRow("Health", value: Fmt.percent(stats.health))
                    detailRow("Cycle Count", value: "\(stats.cycleCount)")
                    if stats.temperature > 0 {
                        detailRow("Temperature", value: Fmt.temperature(stats.temperature))
                    }
                    if !stats.isCharging && stats.timeRemaining > 0 {
                        detailRow("Time Remaining", value: Fmt.timeRemaining(stats.timeRemaining))
                    }
                }
            } else {
                Text("No battery detected")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 260)
    }

    private var batteryIcon: String {
        if stats.isCharging { return "battery.100.bolt" }
        if stats.level > 75 { return "battery.100" }
        if stats.level > 50 { return "battery.75" }
        if stats.level > 25 { return "battery.50" }
        return "battery.25"
    }

    private var batteryColor: Color {
        if stats.isCharging { return .green }
        if stats.level < 20 { return .red }
        if stats.level < 40 { return .orange }
        return .green
    }

    private func detailRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, design: .monospaced))
        }
    }
}
