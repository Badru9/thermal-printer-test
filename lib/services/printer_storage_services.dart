import 'dart:convert';
import 'dart:developer'; // Untuk logging
import 'package:shared_preferences/shared_preferences.dart';
import '../models/usb_printer_model.dart';

class PrinterStorageService {
  static const String _keyConnectedPrinters = 'connected_usb_printers';

  // Memuat daftar printer yang pernah terhubung dari Shared Preferences
  Future<List<UsbPrinterModel>> loadConnectedPrinters() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? printersJson = prefs.getString(_keyConnectedPrinters);
      if (printersJson == null) {
        return [];
      }
      final List<dynamic> jsonList = jsonDecode(printersJson) as List<dynamic>;
      return jsonList
          .map((json) => UsbPrinterModel.fromJson(json as Map<String, dynamic>))
          .toList();
    } catch (e) {
      log('Error loading connected printers from storage: $e');
      return []; // Mengembalikan list kosong jika ada error
    }
  }

  // Menyimpan daftar printer yang diperbarui ke Shared Preferences
  Future<void> saveConnectedPrinters(List<UsbPrinterModel> printers) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String printersJson = jsonEncode(
        printers.map((p) => p.toJson()).toList(),
      );
      await prefs.setString(_keyConnectedPrinters, printersJson);
    } catch (e) {
      log('Error saving connected printers to storage: $e');
    }
  }

  // Menambahkan printer baru ke daftar printer yang pernah terhubung
  Future<void> addConnectedPrinter(UsbPrinterModel printer) async {
    final List<UsbPrinterModel> currentPrinters = await loadConnectedPrinters();
    // Hanya tambahkan jika belum ada di daftar
    if (!currentPrinters.contains(printer)) {
      currentPrinters.add(printer);
      await saveConnectedPrinters(currentPrinters);
      log('Printer ${printer.deviceName} added to previously connected list.');
    }
  }

  // Menghapus printer dari daftar printer yang pernah terhubung
  Future<void> removeConnectedPrinter(UsbPrinterModel printer) async {
    final List<UsbPrinterModel> currentPrinters = await loadConnectedPrinters();
    final initialLength = currentPrinters.length;
    currentPrinters.removeWhere((p) => p == printer);
    if (currentPrinters.length < initialLength) {
      await saveConnectedPrinters(currentPrinters);
      log(
        'Printer ${printer.deviceName} removed from previously connected list.',
      );
    }
  }
}
