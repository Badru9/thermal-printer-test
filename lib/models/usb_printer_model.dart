import 'package:thermal_printer/thermal_printer.dart'
    show PrinterDevice, UsbPrinterInput;

class UsbPrinterModel {
  final String deviceName;
  final String vendorId;
  final String productId;

  UsbPrinterModel({
    required this.deviceName,
    required this.vendorId,
    required this.productId,
  });

  // Factory constructor untuk membuat UsbPrinterModel dari PrinterDevice yang ditemukan
  factory UsbPrinterModel.fromPrinterDevice(PrinterDevice device) {
    return UsbPrinterModel(
      deviceName: device.name ?? 'Unknown Device',
      vendorId: device.vendorId ?? '0',
      productId: device.productId ?? '0',
    );
  }

  // Mengubah UsbPrinterModel menjadi UsbPrinterInput untuk paket thermal_printer
  UsbPrinterInput toUsbPrinterInput() {
    return UsbPrinterInput(
      name: deviceName,
      vendorId: vendorId,
      productId: productId,
    );
  }

  // Mengubah objek menjadi Map (JSON) untuk disimpan
  Map<String, dynamic> toJson() {
    return {
      'deviceName': deviceName,
      'vendorId': vendorId,
      'productId': productId,
    };
  }

  // Membuat objek dari Map (JSON) yang dimuat dari penyimpanan
  factory UsbPrinterModel.fromJson(Map<String, dynamic> json) {
    return UsbPrinterModel(
      deviceName: json['deviceName'] as String,
      vendorId: json['vendorId'] as String,
      productId: json['productId'] as String,
    );
  }

  @override
  String toString() {
    return 'UsbPrinterModel{name: $deviceName, vendorId: $vendorId, productId: $productId}';
  }

  // Penting untuk membandingkan objek (misal: saat mengecek duplikasi di list)
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is UsbPrinterModel &&
        other.vendorId == vendorId &&
        other.productId == productId; // Cukup bandingkan VID/PID
  }

  @override
  int get hashCode => vendorId.hashCode ^ productId.hashCode;
}
