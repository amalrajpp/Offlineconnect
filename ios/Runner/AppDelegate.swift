import Flutter
import UIKit
import CoreBluetooth

/**
 * AppDelegate with a MethodChannel handler for BLE peripheral advertising.
 *
 * Strategy:
 * - iOS cannot include manufacturer data or service data in CBPeripheralManager ads.
 * - We encode the compact 17-byte payload as Base64 in the LocalName: "OC:{base64}".
 * - Base64 of 17 bytes = 24 chars. "OC:" + 24 = 27 bytes \u2264 29-byte LocalName budget. ✅
 * - Android's flutter_blue_plus reads LocalName from raw BLE scan packets (AD type 0x09)
 *   without any GATT connection \u2014 this is what makes cross-platform discovery work.
 *
 * Handles two methods:
 * - `startAdvertising`: begins BLE advertisement with encoded payload in LocalName.
 * - `stopAdvertising`: stops the current BLE advertisement.
 */
@main
@objc class AppDelegate: FlutterAppDelegate {

    private let channelName = "com.redstring/ble_advertiser"
    private let serviceUUID = CBUUID(string: "0000FFF0-0000-1000-8000-00805F9B34FB")

    private var peripheralManager: CBPeripheralManager?
    private var pendingAdvertData: [String: Any]?
    private var advertisingResult: FlutterResult?

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)

        guard let controller = window?.rootViewController as? FlutterViewController else {
            return super.application(application, didFinishLaunchingWithOptions: launchOptions)
        }

        let channel = FlutterMethodChannel(name: channelName, binaryMessenger: controller.binaryMessenger)
        channel.setMethodCallHandler { [weak self] (call, result) in
            guard let self = self else { return }
            switch call.method {
            case "startAdvertising":
                self.handleStartAdvertising(call: call, result: result)
            case "stopAdvertising":
                self.handleStopAdvertising(result: result)
            default:
                result(FlutterMethodNotImplemented)
            }
        }

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    private func handleStartAdvertising(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let _ = args["manufacturerId"] as? Int,
              let payloadBytes = args["payload"] as? FlutterStandardTypedData else {
            result(FlutterError(code: "INVALID_ARGS",
                                message: "manufacturerId and payload are required",
                                details: nil))
            return
        }

        let uuidBytes = payloadBytes.data.prefix(16)
        let uuidString = uuidBytes.map { String(format: "%02hhx", $0) }.joined()
        let formattedUUID = "\(uuidString.prefix(8))-\(uuidString.dropFirst(8).prefix(4))-\(uuidString.dropFirst(12).prefix(4))-\(uuidString.dropFirst(16).prefix(4))-\(uuidString.dropFirst(20))"

        let dynamicUUID = CBUUID(string: formattedUUID)
        let advertData: [String: Any] = [
            CBAdvertisementDataServiceUUIDsKey: [dynamicUUID]
        ]

        pendingAdvertData = advertData
        advertisingResult = result

        if peripheralManager == nil {
            // Initialise for the first time — advertising starts once poweredOn fires.
            peripheralManager = CBPeripheralManager(delegate: self, queue: DispatchQueue.main,
                                                    options: [CBPeripheralManagerOptionShowPowerAlertKey: true])
        } else {
            startAdvertisingIfReady()
        }
    }

    private func handleStopAdvertising(result: FlutterResult) {
        peripheralManager?.stopAdvertising()
        result(true)
    }

    /// Starts advertising immediately if the adapter is ready; otherwise deferred
    /// to `peripheralManagerDidUpdateState` when `.poweredOn` fires.
    private func startAdvertisingIfReady() {
        guard let manager = peripheralManager else {
            advertisingResult?(FlutterError(code: "ADV_FAILED", message: "Manager not initialized", details: nil))
            advertisingResult = nil
            return
        }

        guard manager.state == .poweredOn else {
            // Not ready yet — will retry from peripheralManagerDidUpdateState.
            // Don't call advertisingResult here; wait for the state change.
            return
        }

        guard let data = pendingAdvertData else { return }

        manager.stopAdvertising()
        manager.startAdvertising(data)
        // advertisingResult is called by peripheralManagerDidStartAdvertising.
    }
}

// MARK: - CBPeripheralManagerDelegate
extension AppDelegate: CBPeripheralManagerDelegate {

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            // Adapter just became ready — start advertising if a request is pending.
            startAdvertisingIfReady()
        case .poweredOff, .unauthorized, .unsupported:
            let msg = "Bluetooth not available (state: \(peripheral.state.rawValue))"
            advertisingResult?(FlutterError(code: "BT_UNAVAILABLE", message: msg, details: nil))
            advertisingResult = nil
            pendingAdvertData = nil
        default:
            // .resetting, .unknown — wait for the next state change.
            break
        }
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error = error {
            advertisingResult?(FlutterError(code: "ADV_FAILED",
                                            message: error.localizedDescription,
                                            details: nil))
        } else {
            advertisingResult?(true)
        }
        // Always clear the callback to avoid double-calling.
        advertisingResult = nil
    }
}
