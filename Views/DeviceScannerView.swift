// DeviceScannerView.swift
// MacGuard - Anti-Theft Alarm for macOS
// Created: 2025-12-18

import SwiftUI
import CoreBluetooth
import IOBluetooth

@MainActor
final class DeviceScannerWindowController {
    static let shared = DeviceScannerWindowController()

    private var presented: (viewModel: DeviceScannerViewModel, window: UtilityWindow)?

    func show(bluetoothManager: BluetoothProximityManager) {
        let presented = self.presented ?? Self.present(bluetoothManager: bluetoothManager)
        self.presented = presented
        presented.viewModel.bluetoothManager = bluetoothManager
        presented.window.show()
        presented.viewModel.startScanning()
    }

    private static func present(bluetoothManager: BluetoothProximityManager)
        -> (viewModel: DeviceScannerViewModel, window: UtilityWindow) {
        let viewModel = DeviceScannerViewModel(bluetoothManager: bluetoothManager)
        let window = UtilityWindow(
            title: "Scan for Devices", size: NSSize(width: 350, height: 400), transparent: true,
            onClose: { [viewModel] in viewModel.stopScanning() },
            content: DeviceScannerContainerView(viewModel: viewModel,
                                                onDismiss: { DeviceScannerWindowController.shared.close() }))
        return (viewModel, window)
    }

    func close() {
        presented?.window.close()
    }
}

/// Shell around `DeviceScan`: parses IOBluetooth/CoreBluetooth callbacks into messages.
/// CoreBluetooth delivers on the main queue (`queue: nil`).
@MainActor
class DeviceScannerViewModel: NSObject, ObservableObject {
    var bluetoothManager: BluetoothProximityManager
    @Published private(set) var scan = DeviceScan.Model()
    /// Exists exactly while scanning.
    @Published private var centralManager: CBCentralManager?

    var isScanning: Bool { centralManager != nil }

    init(bluetoothManager: BluetoothProximityManager) {
        self.bluetoothManager = bluetoothManager
    }

    func startScanning() {
        guard !isScanning else { return }
        scan = DeviceScan.Model()
        send(.pairedLoaded(loadPairedDevices()))
        // BLE scan supplies RSSI and binds BLE-capable devices
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    private func send(_ msg: DeviceScan.Msg) {
        let (next, effects) = DeviceScan.update(scan, msg)
        scan = next
        for effect in effects {
            switch effect {
            case .log(let category, let message):
                logActivity(category, message)
            }
        }
    }

    private func loadPairedDevices() -> [DiscoveredDevice] {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return [] }
        return paired.compactMap { ioDevice in
            guard let name = ioDevice.name, !name.isEmpty else { return nil }
            let connected = ioDevice.isConnected()
            logActivity(.bluetooth, "Paired device: \(name) (addr: \(ioDevice.addressString ?? "?"), connected: \(connected))")
            return DiscoveredDevice(
                id: UUID(), name: name,
                classicAddress: ioDevice.addressString.flatMap(BluetoothAddress.init),
                isConnected: connected,
                signal: connected ? RSSI(Int(ioDevice.rawRSSI())) : nil)
        }
    }

    func stopScanning() {
        centralManager?.stopScan()
        centralManager = nil
    }

    func select(_ device: TrustedDevice) {
        if bluetoothManager.addTrustedDevice(device) {
            logActivity(.bluetooth, "Added device: \(device.name) (classic: \(device.isClassicBluetooth))")
        }
    }

    func rowState(for device: DiscoveredDevice) -> DiscoveredDevice.RowState {
        device.rowState(trusted: bluetoothManager.trustedDevices)
    }
}

extension DeviceScannerViewModel: @MainActor CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            central.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
            logActivity(.bluetooth, "Started BLE scanning to identify device types")
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard let ad = Advertisement(name: peripheral.name, peripheral: peripheral.identifier,
                                     rawRSSI: RSSI.intValue) else { return }
        send(.advertised(ad))
    }
}

/// Container view with glass styling
struct DeviceScannerContainerView: View {
    @ObservedObject var viewModel: DeviceScannerViewModel
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header with glass background
            HStack(spacing: Theme.Spacing.md) {
                if viewModel.isScanning {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Scanning for paired devices...")
                        .font(.body)
                        .foregroundStyle(.secondary)
                } else {
                    ZStack {
                        GlassIconCircle(size: 28, material: .selection)
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.Accent.primary)
                    }
                    Text("Select a paired device")
                        .font(.body.weight(.medium))
                }
                Spacer()
            }
            .padding(Theme.Spacing.lg)
            .background {
                GlassBackground(material: .headerView, cornerRadius: 0)
            }

            // Device list
            if viewModel.scan.devices.isEmpty {
                emptyStateView
            } else {
                deviceListView
            }

            // Footer with glass background
            HStack {
                Button {
                    onDismiss()
                } label: {
                    Text("Cancel")
                        .frame(width: 70)
                }
                .buttonStyle(GlassSecondaryButtonStyle())

                Spacer()

                Button {
                    if viewModel.isScanning {
                        viewModel.stopScanning()
                    } else {
                        viewModel.startScanning()
                    }
                } label: {
                    Label(
                        viewModel.isScanning ? "Stop" : "Rescan",
                        systemImage: viewModel.isScanning ? "stop.fill" : "arrow.clockwise"
                    )
                }
                .buttonStyle(GlassBorderedProminentButtonStyle(tint: Theme.Accent.primary))
            }
            .padding(Theme.Spacing.lg)
            .background {
                GlassBackground(material: .headerView, cornerRadius: 0)
            }
        }
        .frame(width: 350, height: 400)
        .background {
            VisualEffectView(
                material: .sidebar,
                blendingMode: .behindWindow,
                isEmphasized: true
            )
            .ignoresSafeArea()
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Spacer()

            ZStack {
                GlassIconCircle(size: 100, material: .selection)
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 40))
                    .foregroundStyle(Theme.Accent.primary)
            }

            VStack(spacing: Theme.Spacing.sm) {
                Text("Looking for paired devices...")
                    .font(.system(.headline, design: .rounded))
                Text("Pair your device in System Settings → Bluetooth first")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Spacer()
        }
    }

    // MARK: - Device List

    private var deviceListView: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Spacing.sm) {
                ForEach(viewModel.scan.devices) { device in
                    DeviceRowButton(device: device, state: viewModel.rowState(for: device)) { trusted in
                        viewModel.select(trusted)
                        onDismiss()
                    }
                }
            }
            .padding(Theme.Spacing.md)
        }
    }

}

// MARK: - Device Row Button

struct DeviceRowButton: View {
    let device: DiscoveredDevice
    let state: DiscoveredDevice.RowState
    let action: (TrustedDevice) -> Void

    @State private var isHovered = false

    private struct RowStyle {
        let iconColor: Color
        let nameColor: Color
        let badge: (text: String, color: Color)
        let showsChevron: Bool
        let isEnabled: Bool
    }

    private var style: RowStyle {
        let status = device.isConnected ? ("Connected", Theme.StateColor.armed) : ("Paired", Color.orange)
        switch state {
        case .selectable:
            return RowStyle(iconColor: Theme.Accent.primary, nameColor: .primary, badge: status,
                            showsChevron: true, isEnabled: true)
        case .alreadyAdded:
            return RowStyle(iconColor: .secondary, nameColor: .secondary, badge: ("Added", Theme.StateColor.armed),
                            showsChevron: false, isEnabled: false)
        case .unavailable:
            return RowStyle(iconColor: Theme.Accent.primary, nameColor: .primary, badge: status,
                            showsChevron: true, isEnabled: false)
        }
    }

    var body: some View {
        switch state {
        case .selectable(let trusted):
            Button { action(trusted) } label: { row(style) }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: Theme.Animation.hoverDuration)) {
                        isHovered = hovering
                    }
                }
        case .alreadyAdded, .unavailable:
            row(style)
        }
    }

    private func row(_ style: RowStyle) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            ZStack {
                GlassIconCircle(size: 40, material: .selection)
                Image(systemName: TrustedDevice.icon(for: device.name))
                    .font(.system(size: 18))
                    .foregroundStyle(style.iconColor)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(device.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(style.nameColor)

                    badge(style.badge.text, style.badge.color)
                }

                HStack(spacing: Theme.Spacing.xs) {
                    if device.isConnected {
                        SignalStrengthView(signal: device.signal)
                        Text(signalStrengthText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        let (label, color) = transportLabel
                        Text(label)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(color)
                            .clipShape(Capsule())
                    }
                }
            }

            Spacer()

            if style.showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(Theme.Spacing.md)
        .background {
            RoundedRectangle(cornerRadius: Theme.CornerRadius.md)
                .fill(.clear)
                .background(
                    VisualEffectView(material: .selection, blendingMode: .withinWindow)
                        .opacity(isHovered && style.isEnabled ? 1 : 0)
                )
                .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.md))
        }
        .glassBorder(cornerRadius: Theme.CornerRadius.md)
        .opacity(style.isEnabled ? 1.0 : 0.6)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color)
            .clipShape(Capsule())
    }

    private var transportLabel: (String, Color) {
        switch device.tracking {
        case .ble: return ("BLE", .blue)
        case .classic: return ("Classic", .orange)
        case .untrackable: return ("No address", .gray)
        }
    }

    private var signalStrengthText: String {
        guard let dBm = device.signal?.dBm else { return "—" }
        if dBm >= -50 { return "Excellent" }
        if dBm >= -60 { return "Good" }
        if dBm >= -70 { return "Fair" }
        return "Weak"
    }
}

/// Visual signal strength indicator
struct SignalStrengthView: View {
    let signal: RSSI?

    private var bars: Int {
        guard let dBm = signal?.dBm else { return 0 }
        if dBm >= -50 { return 4 }
        if dBm >= -60 { return 3 }
        if dBm >= -70 { return 2 }
        return 1
    }

    private var color: Color {
        switch bars {
        case 4: return .green
        case 3: return .green
        case 2: return .yellow
        default: return .orange
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(index < bars ? color : Color.gray.opacity(0.3))
                    .frame(width: 3, height: CGFloat(4 + index * 2))
            }
        }
    }
}
