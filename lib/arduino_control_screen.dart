import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:permission_handler/permission_handler.dart';
import 'ble_service.dart';

class ArduinoControllerScreen extends StatefulWidget {
  const ArduinoControllerScreen({super.key});

  @override
  State<ArduinoControllerScreen> createState() => _ArduinoControllerScreenState();
}

class _ArduinoControllerScreenState extends State<ArduinoControllerScreen> {
  final BleService _bleService = BleService();

  List<BluetoothDevice> _pairedDevices = [];
  BluetoothDevice? _selectedDevice;
  bool _isConnected = false;
  bool _isConnecting = false;
  bool _isScanning = false;
  bool _isLedOn = false;
  String _statusMessage = 'Initializing...';

  StreamSubscription? _scanSub;
  StreamSubscription? _isScanningSub;

  @override
  void initState() {
    super.initState();
    _scanSub = _bleService.devicesStream.listen((devices) {
      if (mounted) {
        setState(() {
          _pairedDevices = devices;
        });
      }
    });

    _isScanningSub = _bleService.isScanningStream.listen((scanning) {
      if (mounted) {
        setState(() {
          _isScanning = scanning;
          if (!scanning && !_isConnected && !_isConnecting) {
            _statusMessage = _pairedDevices.isEmpty
                ? 'No BLE devices found. Tap refresh to scan again.'
                : 'Select a device from the dropdown';
          }
        });
      }
    });

    _requestPermissionsAndScan();
  }

  Future<void> _requestPermissionsAndScan() async {
    setState(() => _statusMessage = 'Requesting Bluetooth permissions...');

    if (!kIsWeb && Platform.isAndroid) {
      final statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
      ].request();

      final scanGranted = statuses[Permission.bluetoothScan]?.isGranted ?? false;
      final connectGranted = statuses[Permission.bluetoothConnect]?.isGranted ?? false;

      // On Android 12+, bluetoothScan & bluetoothConnect are required
      if (!scanGranted && !connectGranted) {
        if (mounted) {
          setState(() {
            _statusMessage = 'Bluetooth permissions denied. Please grant them in settings.';
          });
        }
        return;
      }
    }

    _startScan();
  }

  Future<void> _startScan() async {
    if (_isConnecting) return;

    setState(() {
      _statusMessage = 'Scanning for BLE devices...';
    });

    await _bleService.startScan();
  }

  void _onDeviceSelected(BluetoothDevice? device) async {
    if (device == null || _isConnecting) return;

    setState(() {
      _selectedDevice = device;
      _isConnecting = true;
      _statusMessage = 'Connecting to ${device.platformName.isNotEmpty ? device.platformName : device.remoteId.str}...';
    });

    bool connected = await _bleService.connect(
      device,
      (receivedData) {
        if (mounted) {
          if (receivedData.contains("ON") || receivedData == '1') {
            setState(() => _isLedOn = true);
          } else if (receivedData.contains("OFF") || receivedData == '0') {
            setState(() => _isLedOn = false);
          }

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text("Arduino: $receivedData"),
              duration: const Duration(seconds: 1),
            ),
          );
        }
      },
      () {
        if (mounted) {
          setState(() {
            _isConnected = false;
            _isConnecting = false;
            _statusMessage = 'Device disconnected.';
          });
        }
      },
    );

    if (mounted) {
      setState(() {
        _isConnecting = false;
        _isConnected = connected;
        _statusMessage = connected
            ? 'Connected to ${device.platformName.isNotEmpty ? device.platformName : device.remoteId.str}'
            : 'Connection failed. Please check device power and try again.';
      });

      if (!connected) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to connect or discover BLE UART service.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _disconnect() async {
    await _bleService.disconnect();
    if (mounted) {
      setState(() {
        _isConnected = false;
        _isConnecting = false;
        _statusMessage = 'Disconnected';
      });
    }
  }

  void _sendSignal(String command) async {
    if (!_isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not connected to any device')),
      );
      return;
    }

    bool success = await _bleService.send(command);
    if (success) {
      setState(() => _isLedOn = (command == '1'));
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to send data to device'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _isScanningSub?.cancel();
    _bleService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Safe dropdown selection check to prevent Flutter crashes
    final BluetoothDevice? currentSelection = _pairedDevices.any(
      (d) => d.remoteId == _selectedDevice?.remoteId,
    )
        ? _pairedDevices.firstWhere(
            (d) => d.remoteId == _selectedDevice?.remoteId,
          )
        : null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Arduino BLE Controller'),
        actions: [
          if (_isScanning)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16.w),
              child: SizedBox(
                width: 20.r,
                height: 20.r,
                child: const CircularProgressIndicator(
                  strokeWidth: 2.5,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Scan for Devices',
              onPressed: _isConnecting ? null : _startScan,
            ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.all(16.r),
          child: Column(
            mainAxisSize: MainAxisSize.max,
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Device dropdown
              DropdownButton<BluetoothDevice>(
                value: currentSelection,
                isExpanded: true,
                hint: Text(_isScanning ? 'Scanning for BLE devices...' : 'Select BLE Device'),
                items: _pairedDevices.map((device) {
                  final String displayName = device.platformName.isNotEmpty
                      ? device.platformName
                      : 'Unknown (${device.remoteId.str})';
                  return DropdownMenuItem<BluetoothDevice>(
                    value: device,
                    child: Text(displayName, overflow: TextOverflow.ellipsis),
                  );
                }).toList(),
                onChanged: (_isConnected || _isConnecting) ? null : _onDeviceSelected,
              ),

              SizedBox(height: 10.h),

              // Status indicator
              Text(
                _statusMessage,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13.sp,
                  color: _isConnected
                      ? Colors.green
                      : (_isConnecting ? Colors.orange : Colors.grey[700]),
                  fontWeight: FontWeight.w500,
                ),
              ),

              if (_isConnecting) ...[
                SizedBox(height: 12.h),
                const CircularProgressIndicator(),
              ],

              if (_isConnected) ...[
                SizedBox(height: 8.h),
                TextButton.icon(
                  onPressed: _disconnect,
                  icon: const Icon(Icons.link_off, color: Colors.red),
                  label: const Text('Disconnect', style: TextStyle(color: Colors.red)),
                ),
              ],

              const Spacer(),

              // Lightbulb visual
              Icon(
                Icons.lightbulb,
                size: 130.r,
                color: _isLedOn ? Colors.amber : Colors.grey[400],
              ),

              SizedBox(height: 20.h),

              // ON / OFF Buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  ElevatedButton.icon(
                    onPressed: _isConnected ? () => _sendSignal('1') : null,
                    icon: const Icon(Icons.power_settings_new),
                    label: Text('Turn ON', style: TextStyle(fontSize: 15.sp)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      padding: EdgeInsets.symmetric(horizontal: 24.w, vertical: 12.h),
                    ),
                  ),
                  ElevatedButton.icon(
                    onPressed: _isConnected ? () => _sendSignal('0') : null,
                    icon: const Icon(Icons.power_off),
                    label: Text('Turn OFF', style: TextStyle(fontSize: 15.sp)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                      foregroundColor: Colors.white,
                      padding: EdgeInsets.symmetric(horizontal: 24.w, vertical: 12.h),
                    ),
                  ),
                ],
              ),

              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}
