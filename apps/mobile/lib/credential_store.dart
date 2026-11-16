import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'connection.dart';

class SecureDeviceStore implements DeviceStore {
  final FlutterSecureStorage storage = const FlutterSecureStorage();
  @override
  Future<DeviceProfile?> load() async {
    final value = await storage.read(key: 'paired_device');
    return value == null
        ? null
        : DeviceProfile.fromJson(jsonDecode(value) as Json);
  }

  @override
  Future<void> save(DeviceProfile profile) =>
      storage.write(key: 'paired_device', value: jsonEncode(profile.toJson()));
  @override
  Future<void> clear() => storage.delete(key: 'paired_device');
}
