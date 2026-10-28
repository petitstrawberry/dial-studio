import CoreBluetooth
import Foundation

/// Connects as a second BLE central and dumps the config service.
///
/// Ulanzi Studio configures the dial over GATT service 0x1971
/// (characteristics FD00 / FD01) while the HID stack owns it, so the same
/// link should be reachable from here.
public final class BLEProbe: NSObject {
    public var onLog: ((String) -> Void)?
    public var onCharacteristic: ((String, CBCharacteristic) -> Void)?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var finished = false

    public override init() {
        super.init()
    }

    public func start(seconds: TimeInterval = 12) {
        central = CBCentralManager(delegate: self, queue: nil, options: [
            CBCentralManagerOptionShowPowerAlertKey: false,
        ])
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, !self.finished else { return }
            self.finished = true
            self.log("done")
            self.central?.stopScan()
            exit(0)
        }
    }

    private func log(_ message: String) {
        onLog?(message)
    }

    private func attach(_ peripheral: CBPeripheral) {
        guard self.peripheral == nil else { return }
        self.peripheral = peripheral
        peripheral.delegate = self
        central?.stopScan()
        log("connecting to " + (peripheral.name ?? "?"))
        central?.connect(peripheral)
    }
}

extension BLEProbe: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            log("bluetooth on")
            let known = central.retrieveConnectedPeripherals(withServices: [CBUUID(string: "1971")])
            if let connected = known.first {
                log("found already-connected peripheral")
                attach(connected)
            } else {
                log("scanning for service 1971")
                central.scanForPeripherals(withServices: [CBUUID(string: "1971")], options: nil)
            }
        case .unauthorized:
            log("bluetooth permission denied")
        case .poweredOff:
            log("bluetooth is off")
        default:
            log("state " + String(describing: central.state))
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        log("advertised: " + (peripheral.name ?? "?"))
        attach(peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("connected; discovering services")
        peripheral.discoverServices(nil)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("connect failed: " + (error?.localizedDescription ?? "?"))
    }
}

extension BLEProbe: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { log("services: " + error.localizedDescription) }
        for service in peripheral.services ?? [] {
            log("service " + service.uuid.uuidString)
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            let properties = characteristic.properties
            var flags: [String] = []
            if properties.contains(.read) { flags.append("read") }
            if properties.contains(.write) { flags.append("write") }
            if properties.contains(.writeWithoutResponse) { flags.append("writeNR") }
            if properties.contains(.notify) { flags.append("notify") }
            if properties.contains(.indicate) { flags.append("indicate") }
            log("  char " + characteristic.uuid.uuidString + " [" + flags.joined(separator: ",") + "]")
            onCharacteristic?(service.uuid.uuidString, characteristic)
        }
    }
}
