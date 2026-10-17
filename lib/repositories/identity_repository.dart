import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import '../services/crypto_service.dart';

class IdentityRepository {
  final FlutterSecureStorage secureStorage;
  final String suffix;
  final CryptoService _cryptoService;

  IdentityRepository({
    FlutterSecureStorage? secureStorage,
    String? suffix,
    CryptoService? cryptoService,
  })  : secureStorage = secureStorage ?? const FlutterSecureStorage(),
        suffix = suffix ?? const String.fromEnvironment('INSTANCE', defaultValue: '1'),
        _cryptoService = cryptoService ?? CryptoService();

  String _key(String base) => '${base}_$suffix';

  Future<void> saveMnemonic(String mnemonic) async {
    await secureStorage.write(key: _key('master_mnemonic'), value: mnemonic);
  }

  Future<String?> getMnemonic() async {
    return await secureStorage.read(key: _key('master_mnemonic'));
  }

  Future<void> saveSignalIdentity(
    IdentityKeyPair keyPair,
    int registrationId, {
    String? masterPublicKeyHex,
  }) async {
    final keySuffix = (masterPublicKeyHex != null && masterPublicKeyHex.isNotEmpty)
        ? '_$masterPublicKeyHex'
        : '';
    await secureStorage.write(
      key: '${_key('signal_identity')}$keySuffix',
      value: base64Encode(keyPair.serialize()),
    );
    await secureStorage.write(
      key: '${_key('signal_registration_id')}$keySuffix',
      value: registrationId.toString(),
    );
  }

  Future<(IdentityKeyPair?, int?)> getSignalIdentity({String? masterPublicKeyHex}) async {
    if (masterPublicKeyHex != null && masterPublicKeyHex.isNotEmpty) {
      final scopedKeyIdent = '${_key('signal_identity')}_$masterPublicKeyHex';
      final scopedKeyReg = '${_key('signal_registration_id')}_$masterPublicKeyHex';
      final savedSignalIdentity = await secureStorage.read(key: scopedKeyIdent);
      final savedRegistrationIdStr = await secureStorage.read(key: scopedKeyReg);

      if (savedSignalIdentity != null && savedRegistrationIdStr != null) {
        final keyPair = IdentityKeyPair.fromSerialized(base64Decode(savedSignalIdentity));
        final registrationId = int.tryParse(savedRegistrationIdStr);
        return (keyPair, registrationId);
      }

      // Check for legacy unscoped storage migration
      final legacyIdent = await secureStorage.read(key: _key('signal_identity'));
      final legacyReg = await secureStorage.read(key: _key('signal_registration_id'));
      if (legacyIdent != null && legacyReg != null) {
        // Conservative ownership verification: check saved mnemonic matches masterPublicKeyHex
        final savedMnemonic = await getMnemonic();
        if (savedMnemonic != null) {
          final isOwner = await _verifyMnemonicOwner(savedMnemonic, masterPublicKeyHex);
          if (isOwner) {
            // Safe to migrate
            await secureStorage.write(key: scopedKeyIdent, value: legacyIdent);
            await secureStorage.write(key: scopedKeyReg, value: legacyReg);
            // Delete legacy unscoped keys
            await secureStorage.delete(key: _key('signal_identity'));
            await secureStorage.delete(key: _key('signal_registration_id'));

            final keyPair = IdentityKeyPair.fromSerialized(base64Decode(legacyIdent));
            final registrationId = int.tryParse(legacyReg);
            return (keyPair, registrationId);
          }
        }
      }
      return (null, null);
    }

    final savedSignalIdentity = await secureStorage.read(key: _key('signal_identity'));
    final savedRegistrationIdStr = await secureStorage.read(key: _key('signal_registration_id'));

    if (savedSignalIdentity != null && savedRegistrationIdStr != null) {
      final keyPair = IdentityKeyPair.fromSerialized(base64Decode(savedSignalIdentity));
      final registrationId = int.tryParse(savedRegistrationIdStr);
      return (keyPair, registrationId);
    }
    return (null, null);
  }

  Future<void> saveCustomProfile(
    String? displayName,
    String? bio, {
    String? masterPublicKeyHex,
  }) async {
    final keySuffix = (masterPublicKeyHex != null && masterPublicKeyHex.isNotEmpty)
        ? '_$masterPublicKeyHex'
        : '';
    final nameKey = '${_key('display_name')}$keySuffix';
    final bioKey = '${_key('bio')}$keySuffix';

    if (displayName != null) {
      await secureStorage.write(key: nameKey, value: displayName);
    } else {
      await secureStorage.delete(key: nameKey);
    }

    if (bio != null) {
      await secureStorage.write(key: bioKey, value: bio);
    } else {
      await secureStorage.delete(key: bioKey);
    }
  }

  Future<(String?, String?)> getCustomProfile({String? masterPublicKeyHex}) async {
    if (masterPublicKeyHex != null && masterPublicKeyHex.isNotEmpty) {
      final scopedNameKey = '${_key('display_name')}_$masterPublicKeyHex';
      final scopedBioKey = '${_key('bio')}_$masterPublicKeyHex';
      final displayName = await secureStorage.read(key: scopedNameKey);
      final bio = await secureStorage.read(key: scopedBioKey);
      if (displayName != null || bio != null) {
        return (displayName, bio);
      }

      // Check legacy migration
      final legacyName = await secureStorage.read(key: _key('display_name'));
      final legacyBio = await secureStorage.read(key: _key('bio'));
      if (legacyName != null || legacyBio != null) {
        final savedMnemonic = await getMnemonic();
        if (savedMnemonic != null && await _verifyMnemonicOwner(savedMnemonic, masterPublicKeyHex)) {
          if (legacyName != null) await secureStorage.write(key: scopedNameKey, value: legacyName);
          if (legacyBio != null) await secureStorage.write(key: scopedBioKey, value: legacyBio);
          await secureStorage.delete(key: _key('display_name'));
          await secureStorage.delete(key: _key('bio'));
          return (legacyName, legacyBio);
        }
      }
      return (null, null);
    }

    final displayName = await secureStorage.read(key: _key('display_name'));
    final bio = await secureStorage.read(key: _key('bio'));
    return (displayName, bio);
  }

  Future<(IdentityKeyPair, int)> rotateSignalIdentity({
    required String masterPublicKeyHex,
  }) async {
    final newKeyPair = generateIdentityKeyPair();
    final newRegId = generateRegistrationId(false);
    await saveSignalIdentity(newKeyPair, newRegId, masterPublicKeyHex: masterPublicKeyHex);
    return (newKeyPair, newRegId);
  }

  Future<bool> _verifyMnemonicOwner(String mnemonic, String expectedMasterPubKeyHex) async {
    try {
      if (!_cryptoService.validateMnemonic(mnemonic)) return false;
      final keyPair = await _cryptoService.generateMasterKeyPair(mnemonic);
      final pubKey = await keyPair.extractPublicKey();
      final hex = pubKey.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
      return hex.toLowerCase() == expectedMasterPubKeyHex.toLowerCase();
    } catch (_) {
      return false;
    }
  }

  Future<void> clearAll({String? masterPublicKeyHex}) async {
    await secureStorage.delete(key: _key('master_mnemonic'));
    if (masterPublicKeyHex != null && masterPublicKeyHex.isNotEmpty) {
      await secureStorage.delete(key: '${_key('signal_identity')}_$masterPublicKeyHex');
      await secureStorage.delete(key: '${_key('signal_registration_id')}_$masterPublicKeyHex');
      await secureStorage.delete(key: '${_key('display_name')}_$masterPublicKeyHex');
      await secureStorage.delete(key: '${_key('bio')}_$masterPublicKeyHex');
    }
    await secureStorage.delete(key: _key('signal_identity'));
    await secureStorage.delete(key: _key('signal_registration_id'));
    await secureStorage.delete(key: _key('display_name'));
    await secureStorage.delete(key: _key('bio'));
  }
}
