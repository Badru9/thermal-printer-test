import 'dart:async';
import 'dart:developer'; // Untuk logging
import 'dart:io'; // Untuk File
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // Untuk rootBundle
import 'package:thermal_print_dekstop/services/printer_storage_services.dart';
import 'package:thermal_printer/esc_pos_utils_platform/esc_pos_utils_platform.dart';
import 'package:thermal_printer/thermal_printer.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart'; // Import untuk debugging gambar

import 'models/usb_printer_model.dart';

// GlobalKey untuk ScaffoldMessenger, memungkinkan akses SnackBar dari mana saja
final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

void main() async {
  // Penting: Pastikan Flutter widgets terinisialisasi sebelum menjalankan runApp
  WidgetsFlutterBinding.ensureInitialized();
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
  final PrinterManager _printerManager = PrinterManager.instance;
  final PrinterStorageService _printerStorageService = PrinterStorageService();

  // State untuk status koneksi dan scanning
  bool _isConnected = false;
  bool _isScanning = false;

  // Daftar printer
  List<UsbPrinterModel> _availableDevices = <UsbPrinterModel>[];
  List<UsbPrinterModel> _previouslyConnectedDevices = <UsbPrinterModel>[];

  // Subscription untuk stream agar bisa di-cancel saat dispose
  StreamSubscription<PrinterDevice>? _discoverySubscription;
  StreamSubscription<USBStatus>? _usbStatusSubscription;

  // Task print yang tertunda (jika printer sempat disconnect)
  List<int>? _pendingPrintTask;

  // Printer yang dipilih pengguna dari daftar
  UsbPrinterModel? _selectedPrinter;
  // Printer yang sedang aktif terhubung
  UsbPrinterModel? _currentConnectedPrinter;

  @override
  void initState() {
    super.initState();
    // Inisialisasi listener status USB
    _initializeUsbStatusListener();
    // Muat daftar printer yang pernah terhubung dari penyimpanan
    _loadPreviouslyConnectedPrinters();
    // Otomatis mulai scan perangkat setelah sedikit delay
    // Menggunakan Future.microtask untuk memastikan build sudah berjalan
    Future.microtask(() {
      _scanDevices();
    });
  }

  @override
  void dispose() {
    // Pastikan semua subscription di-cancel untuk mencegah memory leaks
    _discoverySubscription?.cancel();
    _usbStatusSubscription?.cancel();
    super.dispose();
  }

  // Memuat daftar printer yang pernah terhubung dari PrinterStorageService
  Future<void> _loadPreviouslyConnectedPrinters() async {
    _previouslyConnectedDevices =
        await _printerStorageService.loadConnectedPrinters();
    // Update UI setelah data dimuat
    setState(() {});
    log('Loaded previously connected printers: $_previouslyConnectedDevices');
  }

  // Menginisialisasi listener untuk status USB printer
  void _initializeUsbStatusListener() {
    try {
      _usbStatusSubscription = _printerManager.stateUSB.listen(
        (status) {
          log('USB Status: $status');

          // Perbarui status koneksi di UI
          setState(() {
            if (status == USBStatus.connected) {
              _isConnected = true;
              // Jika ada task print tertunda dan printer terhubung, coba kirim
              if (_pendingPrintTask != null) {
                log('Executing pending print task...');
                // Beri sedikit waktu untuk koneksi stabil sebelum kirim print
                Future.delayed(const Duration(milliseconds: 1000), () async {
                  try {
                    await _printerManager.send(
                      type: PrinterType.usb,
                      bytes: _pendingPrintTask!,
                    );
                    _pendingPrintTask = null; // Hapus task setelah berhasil
                    _showMessage('Pending print job sent successfully!');
                    log('Pending print job executed.');
                  } catch (e) {
                    _showMessage('Failed to send pending print job: $e');
                    log('Error sending pending print job: $e');
                  }
                });
              }
            } else if (status == USBStatus.none) {
              _isConnected = false;
              _currentConnectedPrinter =
                  null; // Clear connected printer jika terputus
              _selectedPrinter =
                  null; // Reset selected when disconnected for clarity
            }
          });
        },
        onError: (error) {
          log('Error in USB status listener: $error');
          // Tangani error listener tanpa crashing aplikasi
          _showMessage(
            'Error in USB status monitor: $error. Printer status may not update.',
          );
          setState(() {
            _isConnected = false;
            _currentConnectedPrinter = null;
          });
        },
      );
    } catch (e) {
      log('Error initializing USB status listener stream: $e');
      // Jika stream itu sendiri gagal diinisialisasi
      _showMessage(
        'Critical error setting up USB listener: $e. USB functions disabled.',
      );
      setState(() {
        _isConnected = false;
        _isScanning = false;
        _availableDevices.clear(); // Clear available devices if critical error
      });
    }
  }

  // Melakukan scan perangkat USB printer yang tersedia
  void _scanDevices() {
    if (_isScanning) return; // Hindari double scan

    setState(() {
      _isScanning = true;
      _availableDevices.clear(); // Bersihkan daftar sebelum scan baru
      // _selectedPrinter dan _currentConnectedPrinter tidak direset di sini
      // agar status koneksi sebelumnya tetap terjaga.
    });

    log('Starting USB device scan...');
    try {
      _discoverySubscription
          ?.cancel(); // Pastikan subscription sebelumnya di-cancel

      _discoverySubscription = _printerManager
          .discovery(type: _printerType, isBle: false)
          .listen(
            (device) {
              log(
                'Found device: ${device.name} - VID: ${device.vendorId} - PID: ${device.productId}',
              );

              final usbPrinterModel = UsbPrinterModel.fromPrinterDevice(device);

              // Tambahkan hanya jika belum ada di daftar
              if (!_availableDevices.any((d) => d == usbPrinterModel)) {
                _availableDevices.add(usbPrinterModel);
                setState(() {}); // Perbarui UI
              }
            },
            onError: (error) {
              log('Error during device discovery stream: $error');
              // Tampilkan pesan error tanpa menghentikan scan atau aplikasi
              _showMessage('Error scanning devices: $error. Please try again.');
            },
            onDone: () {
              setState(() {
                _isScanning = false;
              });
              log(
                'Device discovery completed. Found ${_availableDevices.length} devices',
              );
              if (_availableDevices.isEmpty &&
                  _previouslyConnectedDevices.isEmpty) {
                // Tampilkan pesan informatif jika tidak ada printer sama sekali
                _showMessage(
                  'No USB printers found. Please check connection and drivers.',
                );
              }
            },
          );

      // Timeout untuk scan
      Future.delayed(const Duration(seconds: 10), () {
        if (_isScanning) {
          log('Scan timed out.');
          _discoverySubscription?.cancel();
          setState(() {
            _isScanning = false;
          });
          if (_availableDevices.isEmpty) {
            _showMessage('Scan completed. No devices found within timeout.');
          }
        }
      });
    } catch (e) {
      log('Error starting device discovery stream: $e');
      setState(() {
        _isScanning = false;
      });
      // Tangani error yang terjadi saat memulai stream discovery
      _showMessage(
        'Failed to start device scan: $e. Ensure necessary permissions are granted.',
      );
    }
  }

  // Memilih printer dari daftar
  void _selectDevice(UsbPrinterModel device) async {
    // Jika memilih printer yang berbeda dari yang sedang dipilih
    if (_selectedPrinter != null && _selectedPrinter != device) {
      // Jika printer yang sedang terhubung adalah yang sebelumnya dipilih, putuskan koneksi dulu
      if (_isConnected && _currentConnectedPrinter == _selectedPrinter) {
        log(
          'Disconnecting from previously connected printer before selecting new one...',
        );
        await _disconnectDevice();
      }
    }

    setState(() {
      _selectedPrinter = device; // Set printer yang dipilih
    });
    _showMessage('Selected device: ${device.deviceName}');
    log('Selected device: ${device.deviceName}');
  }

  // Menghubungkan ke printer yang dipilih
  Future<void> _connectDevice() async {
    if (_selectedPrinter == null) {
      _showMessage('Please select a printer first');
      return;
    }

    // Jika sudah terhubung ke printer yang sama
    if (_isConnected && _currentConnectedPrinter == _selectedPrinter) {
      _showMessage('Already connected to this printer.');
      return;
    }

    // Jika terhubung ke printer yang berbeda, putuskan dulu
    if (_isConnected && _currentConnectedPrinter != _selectedPrinter) {
      await _disconnectDevice();
    }

    setState(() {
      _isConnected = false;
      _currentConnectedPrinter = null;
    });

    try {
      log('Attempting to connect to: ${_selectedPrinter!.deviceName}');

      final success = await _printerManager.connect(
        type: PrinterType.usb,
        model: _selectedPrinter!.toUsbPrinterInput(), // Gunakan UsbPrinterInput
      );

      if (success == true) {
        setState(() {
          _isConnected = true;
          _currentConnectedPrinter =
              _selectedPrinter; // Set printer yang sedang terhubung
        });
        // Simpan ke daftar printer yang pernah terhubung
        await _printerStorageService.addConnectedPrinter(_selectedPrinter!);
        await _loadPreviouslyConnectedPrinters(); // Muat ulang daftar untuk update UI
        _showMessage(
          'Connected successfully to ${_selectedPrinter!.deviceName}',
        );
        log(
          'Successfully connected to printer: ${_selectedPrinter!.deviceName}',
        );
      } else {
        _showMessage('Failed to connect to printer.');
        log('Connection failed: _printerManager.connect returned false.');
      }
    } catch (e) {
      log('Error connecting to printer: $e');
      _showMessage(
        'Connection error: $e. Make sure drivers are installed and printer is on.',
      );
      setState(() {
        _isConnected = false;
        _currentConnectedPrinter = null;
      });
    }
  }

  // Memutuskan koneksi dari printer
  Future<void> _disconnectDevice() async {
    if (!_isConnected) {
      _showMessage('Not currently connected to any printer.');
      return;
    }

    try {
      log('Attempting to disconnect from printer...');
      await _printerManager.disconnect(type: PrinterType.usb);
      setState(() {
        _isConnected = false;
        _currentConnectedPrinter = null; // Hapus printer yang sedang terhubung
        _selectedPrinter = null; // Clear selected on disconnect for UX
      });
      _showMessage('Disconnected successfully.');
      log('Disconnected from printer.');
    } catch (e) {
      log('Error disconnecting printer: $e');
      _showMessage('Disconnect error: $e');
    }
  }

  // Fungsi untuk mencetak struk tes
  Future<void> _printTestReceipt() async {
    // Pastikan ada printer yang terhubung
    if (_currentConnectedPrinter == null || !_isConnected) {
      _showMessage('Please connect to a printer first');
      return;
    }

    List<int> bytes = []; // Buffer untuk data print

    try {
      CapabilityProfile profile;
      try {
        // Coba memuat profil 'POS-80' untuk printer 80mm
        profile = await CapabilityProfile.load(name: 'POS-80');
        log('Successfully loaded POS-80 profile.');
      } catch (e) {
        log('Could not load POS-80 profile, trying Generic: $e');
        // Fallback ke profil generik jika 'POS-80' tidak tersedia
        profile = await CapabilityProfile.load();
        log('Using generic default profile.');
      }

      // Inisialisasi generator ESC/POS dengan PaperSize yang tepat
      final generator = Generator(PaperSize.mm80, profile);

      // Set encoding untuk karakter yang benar
      bytes += generator.setGlobalCodeTable(
        'CP1252',
      ); // Atau CP850, dll., tergantung printer

      // --- LOGO PRINTING SECTION ---
      try {
        final ByteData data = await rootBundle.load('assets/images/logo.jpg');
        final Uint8List imageBytes = data.buffer.asUint8List();
        final decodedImage = img.decodeImage(imageBytes);

        if (decodedImage == null) {
          log(
            'DEBUG: decodedImage is NULL for assets/images/logo.jpg. Check file integrity or format.',
          );
          _showMessage(
            'Failed to decode logo image. Printing text header instead.',
          );
          bytes += generator.text(
            '*** LOGO DECODE FAILED ***',
            styles: const PosStyles(align: PosAlign.center),
          );
        } else {
          log(
            'DEBUG: Image decoded successfully. Width: ${decodedImage.width}, Height: ${decodedImage.height}',
          );

          // --- DEBUGGING: Simpan gambar yang diproses ke file ---
          try {
            // Menggunakan getApplicationSupportDirectory() yang lebih stabil untuk desktop
            final directory = await getApplicationSupportDirectory();
            final file = File('${directory.path}/dithered_logo.png');
            await file.writeAsBytes(
              img.encodePng(
                img.ditherImage(
                  img.luminanceThreshold(
                    img.grayscale(img.copyResize(decodedImage, width: 384)),
                    threshold: 128,
                  ),
                ),
              ),
            );
            log('DEBUG: Saved dithered image to: ${file.path}');
            _showMessage(
              'Saved processed logo to ${file.path}',
            ); // Info ke user
          } catch (e) {
            log('DEBUG: Failed to save dithered image for debugging: $e');
            _showMessage(
              'Failed to save processed logo for debug. Check permissions.',
            );
          }
          // --- END DEBUGGING ---

          int targetWidth = 384; // Optimal untuk printer thermal 80mm
          img.Image resizedImage = img.copyResize(
            decodedImage,
            width: targetWidth,
            interpolation: img.Interpolation.linear,
          );
          img.Image grayscaleImage = img.grayscale(resizedImage);
          img.Image binaryImage = img.luminanceThreshold(
            grayscaleImage,
            threshold:
                128, // Anda bisa menyesuaikan nilai ini untuk hasil optimal
          );
          img.Image ditheredImage = img.ditherImage(binaryImage);

          // Gunakan imageRaster dengan metode bitImageRaster
          bytes += generator.imageRaster(
            ditheredImage,
            align: PosAlign.center,
            imageFn:
                PosImageFn
                    .bitImageRaster, // Metode terbaik untuk thermal printer
          );

          // Opsional: Jika bitImageRaster tidak berfungsi, Anda bisa mencoba generator.image()
          // bytes += generator.image(ditheredImage);
        }
      } catch (e) {
        log('Error loading or processing logo image: $e');
        _showMessage('Error with logo: $e. Printing text header instead.');
        bytes += generator.text(
          '* INEEDABEUTY - LOGO ERROR *',
          styles: const PosStyles(
            align: PosAlign.center,
            bold: true,
            height: PosTextSize.size2,
          ),
        );
      }
      bytes += generator.emptyLines(
        1,
      ); // Tetap tambahkan baris kosong setelah logo/error
      // --- END LOGO PRINTING SECTION ---

      bytes += generator.text(
        'TEST STRINGS:',
        styles: const PosStyles(bold: true),
      );
      bytes += generator.text('ABCDEFGHIJKLMNOPQRSTUVWXYZ');
      bytes += generator.text('1234567890');
      bytes += generator.emptyLines(1);

      bytes += generator.text(
        'ineedabeuty',
        styles: const PosStyles(align: PosAlign.center, bold: true),
      );
      bytes += generator.text(
        'Karangpawitan, Garut, Indonesia', // Lokasi saat ini
        styles: const PosStyles(align: PosAlign.center),
      );
      bytes += generator.text(
        'Tel: +62 812-3456-7890',
        styles: const PosStyles(align: PosAlign.center),
      );
      bytes += generator.emptyLines(1);

      bytes += generator.text(
        'Date: ${DateTime.now().toLocal().toString().split('.')[0]}',
        styles: const PosStyles(align: PosAlign.left),
      );
      bytes += generator.text(
        'Receipt #: ${DateTime.now().millisecondsSinceEpoch}',
      );
      bytes += generator.emptyLines(1);

      bytes += generator.text('================================');
      bytes += generator.text('ITEMS', styles: const PosStyles(bold: true));
      bytes += generator.text('================================');

      // Contoh Item dengan format rapi
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
          text: 'Service Charge',
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

      // Bagian Total
      bytes += generator.text('================================');
      bytes += generator.row([
        PosColumn(
          width: 9,
          text: 'SUBTOTAL',
          styles: const PosStyles(align: PosAlign.left, bold: true),
        ),
        PosColumn(
          width: 3,
          text: '75.000',
          styles: const PosStyles(align: PosAlign.right, bold: true),
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

      // Info Pembayaran
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

      // Potong kertas
      bytes += generator.feed(3); // Majukan kertas 3 baris
      bytes += generator.cut(); // Potong kertas

      log('Attempting to send print job...');
      await _printerManager.send(type: PrinterType.usb, bytes: bytes);

      _showMessage('Print job sent successfully!');
      log('Print job sent to printer');
    } catch (e) {
      log('Error printing: $e');
      _showMessage('Print failed: $e');
      _pendingPrintTask =
          bytes; // Simpan task print untuk dicoba kembali jika printer disconnected
      log('Print task saved for retry upon reconnection.');
    }
  }

  // Fungsi untuk menampilkan SnackBar message
  void _showMessage(String message) {
    // Menggunakan GlobalKey untuk memastikan akses ScaffoldMessenger yang stabil
    Future.microtask(() {
      scaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
      );
      if (scaffoldMessengerKey.currentState == null) {
        log(
          'Warning: ScaffoldMessengerState is null. Could not show SnackBar: $message',
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      // Mengaitkan GlobalKey dengan ScaffoldMessenger
      scaffoldMessengerKey: scaffoldMessengerKey,
      title: 'USB Thermal Printer',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true, // Menggunakan Material 3 design
        appBarTheme: const AppBarTheme(
          color: Colors.blue, // Warna AppBar
          foregroundColor: Colors.white, // Warna teks dan ikon di AppBar
        ),
      ),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('USB Thermal Printer - POS Demo'),
          elevation: 2,
        ),
        body: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Kartu Status Koneksi Printer
              Card(
                elevation: 4,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color:
                              _isConnected
                                  ? Colors.green.shade50
                                  : Colors.red.shade50,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          _isConnected ? Icons.usb : Icons.usb_off,
                          color:
                              _isConnected
                                  ? Colors.green.shade700
                                  : Colors.red.shade700,
                          size: 36,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'USB Printer Status',
                              style: Theme.of(context).textTheme.titleLarge
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 6),
                            Chip(
                              label: Text(
                                _isConnected ? 'CONNECTED' : 'DISCONNECTED',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              backgroundColor:
                                  _isConnected ? Colors.green : Colors.red,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 0,
                              ),
                              labelPadding: EdgeInsets.zero,
                            ),
                            if (_currentConnectedPrinter != null) ...[
                              const SizedBox(height: 10),
                              Text(
                                'Device: ${_currentConnectedPrinter!.deviceName}',
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                              Text(
                                'VID: ${_currentConnectedPrinter!.vendorId} | PID: ${_currentConnectedPrinter!.productId}',
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

              // Tombol Kontrol (Scan, Connect, Disconnect)
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _isScanning ? null : _scanDevices,
                      icon:
                          _isScanning
                              ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  color: Colors.white,
                                ),
                              )
                              : const Icon(Icons.search, size: 20),
                      label: Text(
                        _isScanning ? 'Scanning...' : 'Scan USB Printers',
                      ),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          vertical: 14,
                          horizontal: 10,
                        ),
                        backgroundColor:
                            _isScanning
                                ? Colors.grey
                                : Theme.of(context).primaryColor,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed:
                          _selectedPrinter == null ||
                                  (_isConnected &&
                                      _currentConnectedPrinter ==
                                          _selectedPrinter)
                              ? null
                              : _connectDevice,
                      icon: const Icon(Icons.link, size: 20),
                      label: const Text('Connect'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          vertical: 14,
                          horizontal: 10,
                        ),
                        backgroundColor:
                            _selectedPrinter == null
                                ? Colors.grey
                                : Colors.green,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: !_isConnected ? null : _disconnectDevice,
                      icon: const Icon(Icons.link_off, size: 20),
                      label: const Text('Disconnect'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          vertical: 14,
                          horizontal: 10,
                        ),
                        backgroundColor:
                            !_isConnected ? Colors.grey : Colors.red,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 24),

              // Daftar Printer yang Pernah Terhubung
              if (_previouslyConnectedDevices.isNotEmpty) ...[
                Text(
                  'Previously Connected Printers',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 120, // Tinggi tetap untuk list horizontal
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: _previouslyConnectedDevices.length,
                    itemBuilder: (context, index) {
                      final device = _previouslyConnectedDevices[index];
                      final isSelected = _selectedPrinter == device;
                      final isCurrentConnected =
                          _currentConnectedPrinter == device;

                      return GestureDetector(
                        onTap: () => _selectDevice(device),
                        onLongPress: () async {
                          bool? confirm = await showDialog<bool>(
                            context: context,
                            builder: (BuildContext context) {
                              return AlertDialog(
                                title: const Text('Remove Printer?'),
                                content: Text(
                                  'Do you want to remove "${device.deviceName}" from previously connected list?',
                                ),
                                actions: <Widget>[
                                  TextButton(
                                    onPressed:
                                        () => Navigator.of(context).pop(false),
                                    child: const Text('Cancel'),
                                  ),
                                  FilledButton(
                                    onPressed:
                                        () => Navigator.of(context).pop(true),
                                    style: FilledButton.styleFrom(
                                      backgroundColor: Colors.red,
                                    ),
                                    child: const Text(
                                      'Remove',
                                      style: TextStyle(color: Colors.white),
                                    ),
                                  ),
                                ],
                              );
                            },
                          );

                          if (confirm == true) {
                            if (isCurrentConnected) {
                              _showMessage(
                                'Cannot remove a currently connected printer. Disconnect first.',
                              );
                              return;
                            }
                            await _printerStorageService.removeConnectedPrinter(
                              device,
                            );
                            await _loadPreviouslyConnectedPrinters();
                            if (_selectedPrinter == device) {
                              setState(() {
                                _selectedPrinter = null;
                              });
                            }
                            _showMessage(
                              '${device.deviceName} removed from history.',
                            );
                          }
                        },
                        child: Card(
                          elevation:
                              isSelected
                                  ? 6
                                  : 2, // Efek elevasi lebih jelas saat dipilih
                          margin: const EdgeInsets.only(right: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(
                              color:
                                  isSelected
                                      ? Theme.of(context).primaryColor
                                      : Colors.transparent,
                              width: isSelected ? 2 : 0,
                            ),
                          ),
                          color:
                              isSelected
                                  ? Theme.of(context).primaryColor.withAlpha(50)
                                  : Theme.of(context).cardColor,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16.0,
                              vertical: 12.0,
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              mainAxisSize:
                                  MainAxisSize
                                      .min, // Penting untuk mencegah overflow
                              children: [
                                Icon(
                                  Icons.print,
                                  color:
                                      isCurrentConnected
                                          ? Colors.green.shade700
                                          : (isSelected
                                              ? Theme.of(context).primaryColor
                                              : Colors.grey[600]),
                                  size: 36,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  device.deviceName,
                                  style: TextStyle(
                                    fontWeight:
                                        isSelected
                                            ? FontWeight.bold
                                            : FontWeight.w500,
                                    color:
                                        isCurrentConnected
                                            ? Colors.green.shade700
                                            : (isSelected
                                                ? Theme.of(context).primaryColor
                                                : Theme.of(
                                                  context,
                                                ).textTheme.bodyLarge?.color),
                                    fontSize: 16,
                                  ),
                                ),
                                Text(
                                  '${device.vendorId}:${device.productId}',
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(color: Colors.grey[600]),
                                ),
                                if (isCurrentConnected)
                                  const Text(
                                    'Connected',
                                    style: TextStyle(
                                      color: Colors.green,
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 24),
              ],

              // Header Daftar Printer Tersedia
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
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).primaryColor.withAlpha(40), // Menggunakan withAlpha
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      '${_availableDevices.length} found',
                      style: TextStyle(
                        color: Theme.of(context).primaryColor.withAlpha(80),
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Daftar Printer Tersedia
              Expanded(
                // Penting: Ini memastikan list mengambil sisa ruang
                child:
                    _availableDevices.isEmpty && !_isScanning
                        ? Center(
                          child: SingleChildScrollView(
                            // Memungkinkan scroll jika konten terlalu besar
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              mainAxisSize:
                                  MainAxisSize
                                      .min, // Penting untuk mencegah overflow
                              children: [
                                Icon(
                                  Icons.print_disabled,
                                  size: 80,
                                  color: Colors.grey[300],
                                ),
                                const SizedBox(height: 20),
                                Text(
                                  'No USB printers found',
                                  style: TextStyle(
                                    color: Colors.grey[500],
                                    fontSize: 20,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  'Make sure your thermal printer is:\n• Connected via USB\n• Powered on\n• Drivers installed',
                                  style: TextStyle(
                                    color: Colors.grey[400],
                                    fontSize: 15,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 20),
                                ElevatedButton.icon(
                                  onPressed: _scanDevices,
                                  icon: const Icon(Icons.refresh),
                                  label: const Text('Scan Again'),
                                  style: ElevatedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 20,
                                      vertical: 12,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                        : ListView.builder(
                          itemCount: _availableDevices.length,
                          itemBuilder: (context, index) {
                            final device = _availableDevices[index];
                            final isSelected = _selectedPrinter == device;
                            final isCurrentConnected =
                                _currentConnectedPrinter == device;

                            return Card(
                              elevation: isSelected ? 6 : 2,
                              margin: const EdgeInsets.only(bottom: 10),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                                side: BorderSide(
                                  color:
                                      isSelected
                                          ? Theme.of(context).primaryColor
                                          : Colors.transparent,
                                  width: isSelected ? 2 : 0,
                                ),
                              ),
                              color:
                                  isSelected
                                      ? Theme.of(
                                        context,
                                      ).primaryColor.withAlpha(50)
                                      : Theme.of(context).cardColor,
                              child: ListTile(
                                contentPadding: const EdgeInsets.all(16),
                                leading: Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color:
                                        isCurrentConnected
                                            ? Colors.green.shade100
                                            : (isSelected
                                                ? Theme.of(context).primaryColor
                                                : Colors.grey.shade100),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Icon(
                                    Icons.print,
                                    color:
                                        isCurrentConnected
                                            ? Colors.green.shade700
                                            : (isSelected
                                                ? Theme.of(context).primaryColor
                                                : Colors
                                                    .grey[700]), // Menggunakan primaryColor
                                    size: 28,
                                  ),
                                ),
                                title: Text(
                                  device.deviceName,
                                  style: TextStyle(
                                    fontWeight:
                                        isSelected
                                            ? FontWeight.bold
                                            : FontWeight.w600,
                                    color:
                                        isCurrentConnected
                                            ? Colors.green.shade700
                                            : (isSelected
                                                ? Theme.of(context).primaryColor
                                                : null), // Menggunakan primaryColor
                                    fontSize: 17,
                                  ),
                                ),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize:
                                      MainAxisSize
                                          .min, // Penting untuk mencegah overflow
                                  children: [
                                    const SizedBox(height: 6),
                                    Text('Vendor ID: ${device.vendorId}'),
                                    Text('Product ID: ${device.productId}'),
                                  ],
                                ),
                                trailing:
                                    isCurrentConnected
                                        ? const Chip(
                                          label: Text(
                                            'ACTIVE',
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 11,
                                            ),
                                          ),
                                          backgroundColor: Colors.green,
                                          padding: EdgeInsets.zero,
                                          labelPadding: EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 0,
                                          ),
                                        )
                                        : (isSelected
                                            ? const Icon(
                                              Icons.check_circle,
                                              color: Colors.blue,
                                              size: 24,
                                            )
                                            : const Icon(
                                              Icons.radio_button_unchecked,
                                              color: Colors.grey,
                                              size: 24,
                                            )),
                                onTap: () => _selectDevice(device),
                              ),
                            );
                          },
                        ),
              ),

              const SizedBox(height: 20),

              ElevatedButton.icon(
                onPressed: _isConnected ? _printTestReceipt : null,
                icon: const Icon(Icons.receipt_long, size: 24),
                label: const Text(
                  'Print Test Receipt',
                  style: TextStyle(fontSize: 16),
                ),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  backgroundColor:
                      _isConnected
                          ? Theme.of(context).primaryColor
                          : Colors.grey[400],
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  elevation: 5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
