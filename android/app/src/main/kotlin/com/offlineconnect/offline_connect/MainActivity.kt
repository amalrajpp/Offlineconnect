package com.offlineconnect.offline_connect

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.provider.Settings
import android.os.ParcelUuid
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer

/**
 * MainActivity with a MethodChannel handler for BLE peripheral advertising.
 *
 * Handles two methods:
 * - `startAdvertising`: begins BLE advertisement with the given manufacturer data payload.
 * - `stopAdvertising`: stops the current BLE advertisement.
 *
 * The manufacturer data is the 14-byte Zero-GATT protocol payload defined in BleService.
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val TAG = "BleAdvertiser"
        private const val CHANNEL = "com.offlineconnect/ble_advertiser"
    }

    private var advertiser: BluetoothLeAdvertiser? = null
    private var currentCallback: AdvertiseCallback? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startAdvertising" -> handleStartAdvertising(call, result)
                    "stopAdvertising" -> handleStopAdvertising(result)
                    "openLocationSettings" -> handleOpenLocationSettings(result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun handleStartAdvertising(call: MethodCall, result: MethodChannel.Result) {
        val manufacturerId = call.argument<Int>("manufacturerId")
        val payloadBytes = call.argument<ByteArray>("payload")

        if (manufacturerId == null || payloadBytes == null) {
            result.error("INVALID_ARGS", "manufacturerId and payload are required", null)
            return
        }

        val bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        val adapter = bluetoothManager?.adapter

        if (adapter == null || !adapter.isEnabled) {
            result.error("BT_OFF", "Bluetooth is not enabled", null)
            return
        }

        advertiser = adapter.bluetoothLeAdvertiser
        if (advertiser == null) {
            result.error("BT_NO_ADV", "BLE advertising is not supported on this device", null)
            return
        }

        // Stop any existing advertisement first.
        stopCurrentAdvertisement()

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(false)
            .setTimeout(0) // Advertise indefinitely
            .build()

        // Build manufacturer-specific data.
        // Note: Android BLE API expects manufacturer ID as a 2-byte little-endian prefix
        // but the AdvertiseData builder handles the ID separately.
        val advertiseData = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .setIncludeTxPowerLevel(false)
            .addManufacturerData(manufacturerId, payloadBytes)
            .build()

        val callback = object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
                Log.d(TAG, "Advertising started successfully")
                result.success(true)
            }

            override fun onStartFailure(errorCode: Int) {
                val errorMsg = when (errorCode) {
                    ADVERTISE_FAILED_DATA_TOO_LARGE -> "Data too large"
                    ADVERTISE_FAILED_TOO_MANY_ADVERTISERS -> "Too many advertisers"
                    ADVERTISE_FAILED_ALREADY_STARTED -> "Already started"
                    ADVERTISE_FAILED_INTERNAL_ERROR -> "Internal error"
                    ADVERTISE_FAILED_FEATURE_UNSUPPORTED -> "Feature unsupported"
                    else -> "Unknown error ($errorCode)"
                }
                Log.e(TAG, "Advertising failed: $errorMsg")
                result.error("ADV_FAILED", errorMsg, null)
            }
        }

        currentCallback = callback
        advertiser?.startAdvertising(settings, advertiseData, callback)
    }

    private fun handleStopAdvertising(result: MethodChannel.Result) {
        stopCurrentAdvertisement()
        result.success(true)
    }

    private fun handleOpenLocationSettings(result: MethodChannel.Result) {
        try {
            val intent = Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            result.success(true)
        } catch (e: ActivityNotFoundException) {
            Log.w(TAG, "Location settings activity not found: ${e.message}")
            result.error("LOCATION_SETTINGS_NOT_FOUND", "Location settings are unavailable", null)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to open location settings: ${e.message}")
            result.error("LOCATION_SETTINGS_ERROR", e.message, null)
        }
    }

    private fun stopCurrentAdvertisement() {
        currentCallback?.let { cb ->
            try {
                advertiser?.stopAdvertising(cb)
            } catch (e: Exception) {
                Log.w(TAG, "Error stopping advertisement: ${e.message}")
            }
        }
        currentCallback = null
    }

    override fun onDestroy() {
        stopCurrentAdvertisement()
        super.onDestroy()
    }
}
