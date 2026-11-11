import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

class BleService {
  BluetoothDevice? targetDevice;
  BluetoothCharacteristic? _writeCharacteristic;
  BluetoothCharacteristic? _notifyCharacteristic;
  StreamSubscription? _notifySub;
  StreamSubscription? _connSub;
  StreamSubscription? _scanSub;

  final _deviceListController = StreamController<List<BluetoothDevice>>.broadcast();
  Stream<List<BluetoothDevice>> get devicesStream => _deviceListController.stream;

  Stream<bool> get isScanningStream => FlutterBluePlus.isScanning;

  /// Check if Bluetooth adapter is turned on and ready.
  Future<bool> ensureBluetoothOn() async {
    try {
      if (await FlutterBluePlus.isSupported == false) {
        debugPrint("Bluetooth is not supported on this device.");
        return false;
      }

      // Prompt to turn on Bluetooth on Android if disabled
      if (!kIsWeb && Platform.isAndroid) {
        if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
          try {
            await FlutterBluePlus.turnOn();
          } catch (e) {
            debugPrint("turnOn error: $e");
          }
        }
      }

      // Wait briefly for Bluetooth state to be 'on'
      await FlutterBluePlus.adapterState
          .where((state) => state == BluetoothAdapterState.on)
          .first
          .timeout(const Duration(seconds: 4));

      return true;
    } catch (e) {
      debugPrint("Error ensuring Bluetooth is on: $e");
      return false;
    }
  }

  /// Start scanning for BLE devices (HM-10, ESP32, etc.)
  Future<void> startScan({Duration timeout = const Duration(seconds: 10)}) async {
    final isReady = await ensureBluetoothOn();
    if (!isReady) return;

    if (FlutterBluePlus.isScanningNow) {
      await FlutterBluePlus.stopScan();
    }

    _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      final Map<String, BluetoothDevice> deviceMap = {};
      for (final r in results) {
        deviceMap[r.device.remoteId.str] = r.device;
      }
      _deviceListController.add(deviceMap.values.toList());
    });

    await FlutterBluePlus.startScan(timeout: timeout);
  }

  Future<void> stopScan() async {
    if (FlutterBluePlus.isScanningNow) {
      await FlutterBluePlus.stopScan();
    }
  }

  /// Connect to the selected device, discover UART services (HM-10 or ESP32 Nordic UART / custom),
  /// and bind write and notify characteristics.
  Future<bool> connect(
    BluetoothDevice device,
    Function(String) onDataReceived,
    Function() onDisconnect,
  ) async {
    try {
      await stopScan();

      // If already connected to another device, disconnect
      if (targetDevice != null && targetDevice != device) {
        await disconnect();
      }

      targetDevice = device;

      // Connect with nonprofit license and safe timeout
      await targetDevice!.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 15),
        autoConnect: false,
      );

      _connSub?.cancel();
      _connSub = targetDevice!.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _cleanupCharacteristics();
          onDisconnect();
        }
      });

      // Request MTU if on Android (improves stability)
      if (!kIsWeb && Platform.isAndroid) {
        try {
          await targetDevice!.requestMtu(512);
        } catch (_) {}
      }

      // Discover GATT services
      List<BluetoothService> services = await targetDevice!.discoverServices();

      BluetoothCharacteristic? writeChar;
      BluetoothCharacteristic? notifyChar;

      // 1. Look for HM-10 / CC2541 characteristic (FFE1)
      for (final s in services) {
        for (final c in s.characteristics) {
          final uuid = c.uuid.str.toLowerCase();
          if (uuid.contains("ffe1")) {
            writeChar = c;
            if (c.properties.notify || c.properties.indicate) {
              notifyChar = c;
            }
            break;
          }
        }
        if (writeChar != null) break;
      }

      // 2. Look for ESP32 Nordic UART Service (NUS)
      // RX: 6E400002 (Write), TX: 6E400003 (Notify)
      if (writeChar == null || notifyChar == null) {
        for (final s in services) {
          for (final c in s.characteristics) {
            final uuid = c.uuid.str.toLowerCase();
            if (uuid.contains("6e400002")) {
              writeChar = c;
            } else if (uuid.contains("6e400003")) {
              notifyChar = c;
            }
          }
        }
      }

      // 3. Fallback: Search for any writable and notify characteristic
      if (writeChar == null) {
        for (final s in services) {
          final sUuid = s.uuid.str.toLowerCase();
          if (sUuid.startsWith("00001800") || sUuid.startsWith("00001801")) continue;
          for (final c in s.characteristics) {
            if (c.properties.write || c.properties.writeWithoutResponse) {
              writeChar = c;
              break;
            }
          }
          if (writeChar != null) break;
        }
      }

      if (notifyChar == null) {
        for (final s in services) {
          final sUuid = s.uuid.str.toLowerCase();
          if (sUuid.startsWith("00001800") || sUuid.startsWith("00001801")) continue;
          for (final c in s.characteristics) {
            if (c.properties.notify || c.properties.indicate) {
              notifyChar = c;
              break;
            }
          }
          if (notifyChar != null) break;
        }
      }

      _writeCharacteristic = writeChar;
      _notifyCharacteristic = notifyChar;

      // Subscribe to notify characteristic if available
      if (_notifyCharacteristic != null) {
        _notifySub?.cancel();
        await _notifyCharacteristic!.setNotifyValue(true);
        _notifySub = _notifyCharacteristic!.onValueReceived.listen((bytes) {
          if (bytes.isNotEmpty) {
            try {
              final received = utf8.decode(bytes).trim();
              onDataReceived(received);
            } catch (_) {
              onDataReceived(String.fromCharCodes(bytes).trim());
            }
          }
        });
      }

      // We consider connection successful if we have a writable characteristic
      return _writeCharacteristic != null;
    } catch (e) {
      debugPrint("BLE connect error: $e");
      return false;
    }
  }

  /// Send payload to Arduino / ESP32.
  Future<bool> send(String data) async {
    if (_writeCharacteristic != null) {
      try {
        final bytes = utf8.encode(data);
        await _writeCharacteristic!.write(
          bytes,
          withoutResponse: _writeCharacteristic!.properties.writeWithoutResponse,
        );
        return true;
      } catch (e) {
        debugPrint("BLE write error: $e");
        return false;
      }
    }
    return false;
  }

  void _cleanupCharacteristics() {
    _notifySub?.cancel();
    _notifySub = null;
    _writeCharacteristic = null;
    _notifyCharacteristic = null;
  }

  Future<void> disconnect() async {
    _cleanupCharacteristics();
    _connSub?.cancel();
    _connSub = null;
    try {
      await targetDevice?.disconnect();
    } catch (_) {}
    targetDevice = null;
  }

  void dispose() {
    _scanSub?.cancel();
    _deviceListController.close();
    disconnect();
  }
}
