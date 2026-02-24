import SwiftUI

/// A single row in the device list, showing drive icon, name, capacity, and badges.
struct DeviceRow: View {

    let device: StorageDevice
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Drive icon
            Image(systemName: device.isExternal ? "externaldrive.fill" : "internaldrive.fill")
                .font(.title2)
                .foregroundStyle(device.isExternal ? .orange : .blue)
                .frame(width: 32)

            // Name + capacity
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(device.name)
                        .font(.headline)

                    Text(device.isExternal ? "External" : "Internal")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            device.isExternal
                                ? Color.orange.opacity(0.15)
                                : Color.blue.opacity(0.15)
                        )
                        .foregroundStyle(device.isExternal ? .orange : .blue)
                        .clipShape(Capsule())
                }

                // Capacity bar
                CapacityBar(fraction: device.usageFraction)
                    .frame(height: 6)

                // Capacity text
                Text("\(device.formattedAvailable) available of \(device.formattedTotal)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Selection checkmark
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.accent)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Capacity Bar

/// A small progress bar showing volume usage.
private struct CapacityBar: View {

    let fraction: Double

    private var barColor: Color {
        switch fraction {
        case 0..<0.7:  return .green
        case 0.7..<0.9: return .yellow
        default:        return .red
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.2))

                RoundedRectangle(cornerRadius: 3)
                    .fill(barColor)
                    .frame(width: geometry.size.width * max(0, min(1, fraction)))
            }
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 8) {
        DeviceRow(
            device: StorageDevice(
                id: "1",
                name: "Macintosh HD",
                volumePath: URL(fileURLWithPath: "/"),
                isExternal: false,
                totalCapacity: 500_000_000_000,
                availableCapacity: 120_000_000_000
            ),
            isSelected: true
        )
        DeviceRow(
            device: StorageDevice(
                id: "2",
                name: "USB Drive",
                volumePath: URL(fileURLWithPath: "/Volumes/USB"),
                isExternal: true,
                totalCapacity: 64_000_000_000,
                availableCapacity: 55_000_000_000
            ),
            isSelected: false
        )
    }
    .padding()
    .frame(width: 400)
}
