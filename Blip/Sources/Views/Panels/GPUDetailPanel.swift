import SwiftUI

struct GPUDetailPanel: View {
    let stats: GPUStats
    let history: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                Image(systemName: "rectangle.3.group")
                    .foregroundStyle(.purple)
                Text("GPU")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(Fmt.percent(stats.utilization))
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
            }

            // GPU info
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Renderer")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(stats.name)
                        .font(.system(size: 11, design: .monospaced))
                }

                if stats.coreCount > 0 {
                    HStack {
                        Text("GPU Cores")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(stats.coreCount)")
                            .font(.system(size: 11, design: .monospaced))
                    }
                }

                HStack {
                    Text("Utilization")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(Fmt.percent(stats.utilization))
                        .font(.system(size: 11, design: .monospaced))
                }
            }

            // Usage bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.purple.opacity(0.1))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(gpuColor)
                        .frame(width: geo.size.width * min(stats.utilization / 100, 1))
                }
            }
            .frame(height: 8)

            // History chart
            DetailChart(data: history, color: .purple, label: "Usage over time")
        }
        .padding(12)
        .frame(width: 260)
    }

    private var gpuColor: Color {
        if stats.utilization > 90 { return .red }
        if stats.utilization > 70 { return .orange }
        return .purple
    }
}
