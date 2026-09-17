import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

class IdentityRepository {
  final FlutterSecureStorage secureStorage = const FlutterSecureStorage();
  final String suffix = const String.fromEnvironment('INSTANCE', defaultValue: '1');
  
  String _key(String base) => '${base}_$suffix';

  Future<void> saveMnemonic(String mnemonic) async {
    await secureStorage.write(key: _key('master_mnemonic'), value: mnemonic);
  }

  Future<String?> getMnemonic() async {
    return await secureStorage.read(key: _key('master_mnemonic'));
  }

  Future<void> saveSignalIdentity(IdentityKeyPair keyPair, int registrationId) async {
    await secureStorage.write(key: _key('signal_identity'), value: base64Encode(keyPair.serialize()));
    await secureStorage.write(key: _key('signal_registration_id'), value: registrationId.toString());
  }

  Future<(IdentityKeyPair?, int?)> getSignalIdentity() async {
    final savedSignalIdentity = await secureStorage.read(key: _key('signal_identity'));
    final savedRegistrationIdStr = await secureStorage.read(key: _key('signal_registration_id'));
    
    if (savedSignalIdentity != null && savedRegistrationIdStr != null) {
      final keyPair = IdentityKeyPair.fromSerialized(base64Decode(savedSignalIdentity));
      final registrationId = int.tryParse(savedRegistrationIdStr);
      return (keyPair, registrationId);
    }
    return (null, null);
  }
  Future<void> saveCustomProfile(String? displayName, String? bio) async {
    if (displayName != null) {
      await secureStorage.write(key: _key('display_name'), value: displayName);
    } else {
      await secureStorage.delete(key: _key('display_name'));
    }
    
    if (bio != null) {
      await secureStorage.write(key: _key('bio'), value: bio);
    } else {
      await secureStorage.delete(key: _key('bio'));
    }
  }

  Future<(String?, String?)> getCustomProfile() async {
    final displayName = await secureStorage.read(key: _key('display_name'));
    final bio = await secureStorage.read(key: _key('bio'));
    return (displayName, bio);
  }


  Future<void> clearAll() async {
    await secureStorage.delete(key: _key('master_mnemonic'));
    await secureStorage.delete(key: _key('signal_identity'));
    await secureStorage.delete(key: _key('signal_registration_id'));
    await secureStorage.delete(key: _key('display_name'));
    await secureStorage.delete(key: _key('bio'));
  }
}
