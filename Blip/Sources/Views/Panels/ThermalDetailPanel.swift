import SwiftUI

struct ThermalDetailPanel: View {
    let thermalLevel: ThermalLevel
    let fanStats: FanStats

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                Image(systemName: "thermometer.medium")
                    .foregroundStyle(thermalColor)
                Text("Thermal")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(thermalLevel.rawValue)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(thermalColor)
            }

            // Thermal state description
            Text(thermalDescription)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Temperatures (only shown when data is available from SMC/helper)
            if fanStats.cpuTemperature != nil || fanStats.gpuTemperature != nil {
                Divider()
                HStack {
                    Image(systemName: "flame")
                        .foregroundStyle(.orange)
                    Text("Temperatures")
                        .font(.system(size: 13, weight: .semibold))
                }

                VStack(alignment: .leading, spacing: 4) {
                    if let cpuTemp = fanStats.cpuTemperature {
                        tempRow("CPU", temp: cpuTemp)
                    }
                    if let gpuTemp = fanStats.gpuTemperature {
                        tempRow("GPU", temp: gpuTemp)
                    }
                }
            }

            // Fan section (only shown when fan data is available)
            if !fanStats.fans.isEmpty {
                Divider()

                HStack {
                    Image(systemName: "fan")
                        .foregroundStyle(.teal)
                    Text("Fans")
                        .font(.system(size: 13, weight: .semibold))
                }

                ForEach(fanStats.fans) { fan in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(fan.name)
                                .font(.system(size: 11))
                            Spacer()
                            Text("\(fan.currentRPM) RPM")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        if fan.maxRPM > 0 {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.teal.opacity(0.1))
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.teal)
                                        .frame(width: geo.size.width * min(Double(fan.currentRPM) / Double(fan.maxRPM), 1))
                                }
                            }
                            .frame(height: 6)
                            HStack {
                                Text("Min: \(fan.minRPM)")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                                Spacer()
                                Text("Max: \(fan.maxRPM)")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 260)
    }

    private func tempRow(_ label: String, temp: Double) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(Fmt.temperature(temp))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(tempColor(temp))
        }
    }

    private func tempColor(_ temp: Double) -> Color {
        if temp > 95 { return .red }
        if temp > 80 { return .orange }
        if temp > 60 { return .yellow }
        return .green
    }

    private var thermalColor: Color {
        switch thermalLevel {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        }
    }

    private var thermalDescription: String {
        switch thermalLevel {
        case .nominal: return "System is running within normal thermal limits."
        case .fair: return "System is slightly warm. Performance is not affected."
        case .serious: return "System is warm. Performance may be throttled."
        case .critical: return "System is overheating. Performance is being reduced."
        }
    }
}
