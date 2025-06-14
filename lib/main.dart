import 'dart:async';
import 'dart:developer';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:thermal_printer/esc_pos_utils_platform/esc_pos_utils_platform.dart';
import 'package:thermal_printer/thermal_printer.dart';
import 'package:image/image.dart' as img;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  // Fixed printer type for USB only (Windows)
  final PrinterType _printerType = PrinterType.usb;

  bool _isConnected = false;
  bool _isScanning = false;
  final PrinterManager _printerManager = PrinterManager.instance;
  List<UsbPrinter> _devices = <UsbPrinter>[];

  StreamSubscription<PrinterDevice>? _subscription;
  StreamSubscription<USBStatus>? _subscriptionUsbStatus;
  USBStatus _currentUsbStatus = USBStatus.none;
  List<int>? _pendingTask;
  UsbPrinter? _selectedPrinter;

  @override
  void initState() {
    super.initState();
    _initializeUsbStatusListener();
    // Auto scan on start
    Future.delayed(const Duration(milliseconds: 500), () {
      _scanDevices();
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _subscriptionUsbStatus?.cancel();
    super.dispose();
  }

  void _initializeUsbStatusListener() {
    try {
      _subscriptionUsbStatus = _printerManager.stateUSB.listen((status) {
        log('USB Status: $status');
        _currentUsbStatus = status;

        setState(() {
          if (status == USBStatus.connected) {
            _isConnected = true;
          } else if (status == USBStatus.none ||
              status != USBStatus.connected) {
            _isConnected = false;
          }
        });

        // Execute pending task if available and connected
        if (status == USBStatus.connected && _pendingTask != null) {
          Future.delayed(const Duration(milliseconds: 1000), () {
            _printerManager.send(type: PrinterType.usb, bytes: _pendingTask!);
            _pendingTask = null;
          });
        }
      });
    } catch (e) {
      log('Error initializing USB status listener: $e');
    }
  }

  void _scanDevices() {
    if (_isScanning) return;

    setState(() {
      _isScanning = true;
      _devices.clear();
    });

    try {
      _subscription?.cancel(); // Cancel previous subscription

      _subscription = _printerManager
          .discovery(type: _printerType, isBle: false)
          .listen(
            (device) {
              log(
                'Found device: ${device.name} - VID: ${device.vendorId} - PID: ${device.productId}',
              );

              final usbPrinter = UsbPrinter(
                deviceName: device.name,
                vendorId: device.vendorId ?? '',
                productId: device.productId ?? '',
              );

              // Avoid duplicates
              if (!_devices.any(
                (d) =>
                    d.vendorId == usbPrinter.vendorId &&
                    d.productId == usbPrinter.productId,
              )) {
                _devices.add(usbPrinter);
                setState(() {});
              }
            },
            onError: (error) {
              log('Error during device discovery: $error');
              _showMessage('Error scanning devices: $error');
            },
            onDone: () {
              setState(() {
                _isScanning = false;
              });
              log(
                'Device discovery completed. Found ${_devices.length} devices',
              );
            },
          );

      // Stop scanning after 10 seconds
      Future.delayed(const Duration(seconds: 10), () {
        if (_isScanning) {
          _subscription?.cancel();
          setState(() {
            _isScanning = false;
          });
        }
      });
    } catch (e) {
      log('Error starting device discovery: $e');
      setState(() {
        _isScanning = false;
      });
      _showMessage('Failed to start device scan: $e');
    }
  }

  void _selectDevice(UsbPrinter device) async {
    // Disconnect previous device if different
    if (_selectedPrinter != null &&
        (_selectedPrinter!.vendorId != device.vendorId ||
            _selectedPrinter!.productId != device.productId)) {
      await _disconnectDevice();
    }

    _selectedPrinter = device;
    setState(() {});
    log('Selected device: ${device.deviceName}');
  }

  Future<void> _connectDevice() async {
    if (_selectedPrinter == null) {
      _showMessage('Please select a printer first');
      return;
    }

    setState(() {
      _isConnected = false;
    });

    try {
      log('Connecting to: ${_selectedPrinter!.deviceName}');

      final success = await _printerManager.connect(
        type: PrinterType.usb,
        model: UsbPrinterInput(
          name: _selectedPrinter!.deviceName,
          productId: _selectedPrinter!.productId,
          vendorId: _selectedPrinter!.vendorId,
        ),
      );

      if (success == true) {
        setState(() {
          _isConnected = true;
        });
        _showMessage('Connected successfully');
        log('Successfully connected to printer');
      } else {
        _showMessage('Failed to connect to printer');
        log('Connection failed');
      }
    } catch (e) {
      log('Error connecting to printer: $e');
      _showMessage('Connection error: $e');
      setState(() {
        _isConnected = false;
      });
    }
  }

  Future<void> _disconnectDevice() async {
    if (_selectedPrinter == null) return;

    try {
      await _printerManager.disconnect(type: PrinterType.usb);
      setState(() {
        _isConnected = false;
      });
      _showMessage('Disconnected successfully');
      log('Disconnected from printer');
    } catch (e) {
      log('Error disconnecting printer: $e');
      _showMessage('Disconnect error: $e');
    }
  }

  Future<void> _printTestReceipt() async {
    if (_selectedPrinter == null) {
      _showMessage('Please select a printer first');
      return;
    }

    if (!_isConnected) {
      _showMessage('Please connect to printer first');
      return;
    }

    List<int> bytes = [];

    try {
      // Load printer profile - fallback to default if specific profile not found
      CapabilityProfile profile;
      try {
        profile = await CapabilityProfile.load(name: 'XP-N160I');
      } catch (e) {
        log('Could not load XP-N160I profile, using default: $e');
        profile = await CapabilityProfile.load();
      }

      final generator = Generator(PaperSize.mm58, profile);

      // Set encoding
      bytes += generator.setGlobalCodeTable('CP1252');

      // Header
      bytes += generator.text(
        'TEST PRINT RECEIPT',
        styles: const PosStyles(
          align: PosAlign.center,
          bold: true,
          height: PosTextSize.size2,
        ),
      );
      bytes += generator.emptyLines(1);

      // Store info
      bytes += generator.text(
        'My Store Windows',
        styles: const PosStyles(align: PosAlign.center, bold: true),
      );
      bytes += generator.text(
        'Jakarta, Indonesia',
        styles: const PosStyles(align: PosAlign.center),
      );
      bytes += generator.text(
        'Tel: +62-21-1234567',
        styles: const PosStyles(align: PosAlign.center),
      );
      bytes += generator.emptyLines(1);

      bytes += generator.text(
        'Date: ${DateTime.now().toString().split('.')[0]}',
        styles: const PosStyles(align: PosAlign.left),
      );
      bytes += generator.text(
        'Receipt #: ${DateTime.now().millisecondsSinceEpoch}',
      );
      bytes += generator.emptyLines(1);

      // Separator line
      bytes += generator.text('================================');
      bytes += generator.text('ITEMS', styles: const PosStyles(bold: true));
      bytes += generator.text('================================');

      // Items with proper formatting
      bytes += generator.row([
        PosColumn(
          width: 7,
          text: 'Coffee Latte',
          styles: const PosStyles(align: PosAlign.left),
        ),
        PosColumn(
          width: 2,
          text: '2x',
          styles: const PosStyles(align: PosAlign.center),
        ),
        PosColumn(
          width: 3,
          text: '50.000',
          styles: const PosStyles(align: PosAlign.right),
        ),
      ]);

      bytes += generator.row([
        PosColumn(
          width: 7,
          text: 'Croissant',
          styles: const PosStyles(align: PosAlign.left),
        ),
        PosColumn(
          width: 2,
          text: '1x',
          styles: const PosStyles(align: PosAlign.center),
        ),
        PosColumn(
          width: 3,
          text: '25.000',
          styles: const PosStyles(align: PosAlign.right),
        ),
      ]);

      bytes += generator.row([
        PosColumn(
          width: 7,
          text: 'Service',
          styles: const PosStyles(align: PosAlign.left),
        ),
        PosColumn(
          width: 2,
          text: '',
          styles: const PosStyles(align: PosAlign.center),
        ),
        PosColumn(
          width: 3,
          text: '7.500',
          styles: const PosStyles(align: PosAlign.right),
        ),
      ]);

      // Print logo if available
      try {
        final ByteData data = await rootBundle.load('assets/ic_launcher.png');
        if (data.lengthInBytes > 0) {
          final Uint8List imageBytes = data.buffer.asUint8List();
          final decodedImage = img.decodeImage(imageBytes);

          if (decodedImage != null) {
            // Resize image to fit thermal printer width
            img.Image resizedImage = img.copyResize(
              decodedImage,
              width: 200, // Suitable for 58mm thermal printer
            );

            // Convert to grayscale for better printing
            img.Image grayscaleImage = img.grayscale(resizedImage);

            bytes += generator.emptyLines(1);
            bytes += generator.imageRaster(
              grayscaleImage,
              align: PosAlign.center,
            );
            bytes += generator.emptyLines(1);
          }
        }
      } catch (e) {
        log('Could not load image: $e');
        // Continue without image
      }

      // Total section
      bytes += generator.text('================================');
      bytes += generator.row([
        PosColumn(
          width: 9,
          text: 'SUBTOTAL',
          styles: const PosStyles(align: PosAlign.left),
        ),
        PosColumn(
          width: 3,
          text: '75.000',
          styles: const PosStyles(align: PosAlign.right),
        ),
      ]);

      bytes += generator.row([
        PosColumn(
          width: 9,
          text: 'TAX (10%)',
          styles: const PosStyles(align: PosAlign.left),
        ),
        PosColumn(
          width: 3,
          text: '7.500',
          styles: const PosStyles(align: PosAlign.right),
        ),
      ]);

      bytes += generator.text('--------------------------------');
      bytes += generator.row([
        PosColumn(
          width: 9,
          text: 'TOTAL',
          styles: const PosStyles(
            align: PosAlign.left,
            bold: true,
            height: PosTextSize.size2,
          ),
        ),
        PosColumn(
          width: 3,
          text: '82.500',
          styles: const PosStyles(
            align: PosAlign.right,
            bold: true,
            height: PosTextSize.size2,
          ),
        ),
      ]);

      bytes += generator.text('================================');

      // Payment info
      bytes += generator.emptyLines(1);
      bytes += generator.text('PAYMENT: CASH');
      bytes += generator.text('PAID: 100.000');
      bytes += generator.text('CHANGE: 17.500');

      // Footer
      bytes += generator.emptyLines(2);
      bytes += generator.text(
        'Thank you for your visit!',
        styles: const PosStyles(align: PosAlign.center, bold: true),
      );
      bytes += generator.text(
        'Please come again',
        styles: const PosStyles(align: PosAlign.center),
      );
      bytes += generator.emptyLines(1);
      bytes += generator.text(
        'Powered by Flutter USB Printer',
        styles: const PosStyles(
          align: PosAlign.center,
          width: PosTextSize.size1,
          height: PosTextSize.size1,
        ),
      );

      // Cut paper
      bytes += generator.feed(3);
      bytes += generator.cut();

      // Send to printer
      await _printerManager.send(type: PrinterType.usb, bytes: bytes);

      _showMessage('Print job sent successfully!');
      log('Print job sent to printer');
    } catch (e) {
      log('Error printing: $e');
      _showMessage('Print failed: $e');
    }
  }

  void _showMessage(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'USB Thermal Printer',
      theme: ThemeData(primarySwatch: Colors.blue, useMaterial3: true),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('USB Thermal Printer - Windows'),
          backgroundColor: Theme.of(context).colorScheme.inversePrimary,
          elevation: 2,
        ),
        body: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Connection Status Card
              Card(
                elevation: 4,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color:
                              _isConnected
                                  ? Colors.green.withAlpha(25)
                                  : Colors.red.withAlpha(25),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(
                          _isConnected ? Icons.usb : Icons.usb_off,
                          color: _isConnected ? Colors.green : Colors.red,
                          size: 32,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'USB Printer Status',
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 4),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: _isConnected ? Colors.green : Colors.red,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                _isConnected ? 'CONNECTED' : 'DISCONNECTED',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            if (_selectedPrinter != null) ...[
                              const SizedBox(height: 8),
                              Text(
                                'Device: ${_selectedPrinter!.deviceName}',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              Text(
                                'VID: ${_selectedPrinter!.vendorId} | PID: ${_selectedPrinter!.productId}',
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: Colors.grey[600]),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // Control Buttons
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _isScanning ? null : _scanDevices,
                      icon:
                          _isScanning
                              ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                              : const Icon(Icons.search),
                      label: Text(_isScanning ? 'Scanning...' : 'Scan USB'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed:
                          _selectedPrinter == null || _isConnected
                              ? null
                              : _connectDevice,
                      icon: const Icon(Icons.link),
                      label: const Text('Connect'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: !_isConnected ? null : _disconnectDevice,
                      icon: const Icon(Icons.link_off),
                      label: const Text('Disconnect'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 24),

              // Device List Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Available USB Printers',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(context).primaryColor.withAlpha(25),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${_devices.length} found',
                      style: TextStyle(
                        color: Theme.of(context).primaryColor,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Device List
              Expanded(
                child:
                    _devices.isEmpty && !_isScanning
                        ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.print_disabled,
                                size: 64,
                                color: Colors.grey[400],
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'No USB printers found',
                                style: TextStyle(
                                  color: Colors.grey[600],
                                  fontSize: 18,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Make sure your thermal printer is:\n• Connected via USB\n• Powered on\n• Drivers installed',
                                style: TextStyle(
                                  color: Colors.grey[500],
                                  fontSize: 14,
                                ),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 16),
                              ElevatedButton.icon(
                                onPressed: _scanDevices,
                                icon: const Icon(Icons.refresh),
                                label: const Text('Scan Again'),
                              ),
                            ],
                          ),
                        )
                        : ListView.builder(
                          itemCount: _devices.length,
                          itemBuilder: (context, index) {
                            final device = _devices[index];
                            final isSelected =
                                _selectedPrinter?.vendorId == device.vendorId &&
                                _selectedPrinter?.productId == device.productId;

                            return Card(
                              elevation: isSelected ? 4 : 1,
                              margin: const EdgeInsets.only(bottom: 8),
                              color:
                                  isSelected
                                      ? Theme.of(
                                        context,
                                      ).primaryColor.withAlpha(25)
                                      : null,
                              child: ListTile(
                                contentPadding: const EdgeInsets.all(12),
                                leading: Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color:
                                        isSelected
                                            ? Theme.of(
                                              context,
                                            ).primaryColor.withAlpha(51)
                                            : Colors.grey.withAlpha(25),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Icon(
                                    Icons.print,
                                    color:
                                        isSelected
                                            ? Theme.of(context).primaryColor
                                            : Colors.grey[600],
                                    size: 24,
                                  ),
                                ),
                                title: Text(
                                  device.deviceName,
                                  style: TextStyle(
                                    fontWeight:
                                        isSelected
                                            ? FontWeight.bold
                                            : FontWeight.w500,
                                    color:
                                        isSelected
                                            ? Theme.of(context).primaryColor
                                            : null,
                                  ),
                                ),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const SizedBox(height: 4),
                                    Text('Vendor ID: ${device.vendorId}'),
                                    Text('Product ID: ${device.productId}'),
                                  ],
                                ),
                                trailing:
                                    isSelected
                                        ? Container(
                                          padding: const EdgeInsets.all(8),
                                          decoration: BoxDecoration(
                                            color:
                                                Theme.of(context).primaryColor,
                                            shape: BoxShape.circle,
                                          ),
                                          child: const Icon(
                                            Icons.check,
                                            color: Colors.white,
                                            size: 16,
                                          ),
                                        )
                                        : const Icon(
                                          Icons.radio_button_unchecked,
                                        ),
                                onTap: () => _selectDevice(device),
                              ),
                            );
                          },
                        ),
              ),

              const SizedBox(height: 16),

              // Print Test Button
              ElevatedButton.icon(
                onPressed: _isConnected ? _printTestReceipt : null,
                icon: const Icon(Icons.receipt_long),
                label: const Text('Print Test Receipt'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  backgroundColor:
                      _isConnected ? Theme.of(context).primaryColor : null,
                  foregroundColor: _isConnected ? Colors.white : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Simplified USB Printer class
class UsbPrinter {
  final String deviceName;
  final String vendorId;
  final String productId;

  UsbPrinter({
    required this.deviceName,
    required this.vendorId,
    required this.productId,
  });

  @override
  String toString() {
    return 'UsbPrinter{name: $deviceName, vendorId: $vendorId, productId: $productId}';
  }
}
