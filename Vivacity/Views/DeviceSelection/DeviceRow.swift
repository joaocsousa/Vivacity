import SwiftUI

/// A single row in the device list, showing drive icon, name, capacity, and badges.
///
/// Styled as a card with rounded corners. Selected cards receive a blue border glow.
struct DeviceRow: View {

    let device: StorageDevice
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 14) {
            // Drive icon — rounded square background
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(device.isExternal ? Color.orange.opacity(0.15) : Color.blue.opacity(0.15))
                    .frame(width: 40, height: 40)

                Image(systemName: device.isExternal ? "externaldrive.fill" : "internaldrive.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(device.isExternal ? .orange : .blue)
            }

            // Name + badge + capacity
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(device.name)
                        .font(.system(size: 14, weight: .semibold))

                    // EXTERNAL / INTERNAL badge
                    Text(device.isExternal ? "EXTERNAL" : "INTERNAL")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.5)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            device.isExternal
                                ? Color.green.opacity(0.15)
                                : Color.blue.opacity(0.15)
                        )
                        .foregroundStyle(device.isExternal ? .green : .cyan)
                        .clipShape(Capsule())

                    // Filesystem type badge
                    Text(device.filesystemType.displayName)
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.5)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.purple.opacity(0.15))
                        .foregroundStyle(Color.purple)
                        .clipShape(Capsule())
                }

                // Capacity bar
                CapacityBar(fraction: device.usageFraction)
                    .frame(height: 6)

                // Capacity text
                Text("\(device.formattedAvailable) available of \(device.formattedTotal) · \(Int(device.usageFraction * 100))% used")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    
                // DEBUG INFO
                Text("Path: \(device.volumePath.path)\nUUID: \(device.volumeUUID)")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            // Selection checkmark — always reserves space for consistent bar widths
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.blue)
                .opacity(isSelected ? 1 : 0)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.unemphasizedSelectedContentBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isSelected ? Color.blue.opacity(0.6) : Color.white.opacity(0.06),
                    lineWidth: isSelected ? 1.5 : 1
                )
        )
        .shadow(
            color: isSelected ? Color.blue.opacity(0.2) : Color.clear,
            radius: 8,
            x: 0,
            y: 0
        )
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.15), value: isSelected)
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
                    .fill(Color(.tertiaryLabelColor).opacity(0.35))

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
                volumeUUID: "preview-mac-hd",
                filesystemType: .apfs,
                isExternal: false,
                totalCapacity: 500_000_000_000,
                availableCapacity: 120_000_000_000
            ),
            isSelected: true
        )
        DeviceRow(
            device: StorageDevice(
                id: "2",
                name: "Samsung T7",
                volumePath: URL(fileURLWithPath: "/Volumes/USB"),
                volumeUUID: "preview-samsung",
                filesystemType: .exfat,
                isExternal: true,
                totalCapacity: 2_000_000_000_000,
                availableCapacity: 1_200_000_000_000
            ),
            isSelected: false
        )
        DeviceRow(
            device: StorageDevice(
                id: "3",
                name: "WD My Passport",
                volumePath: URL(fileURLWithPath: "/Volumes/WD"),
                volumeUUID: "preview-wd",
                filesystemType: .fat32,
                isExternal: true,
                totalCapacity: 1_000_000_000_000,
                availableCapacity: 50_000_000_000
            ),
            isSelected: false
        )
    }
    .padding(16)
    .frame(width: 500)
    .background(Color(.controlBackgroundColor))
}
