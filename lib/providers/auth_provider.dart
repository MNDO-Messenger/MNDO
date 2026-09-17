import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:cryptography/cryptography.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import '../repositories/identity_repository.dart';
import '../services/crypto_service.dart';
import '../services/nostr_relay_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AuthProvider extends ChangeNotifier {
  final IdentityRepository identityRepo;
  final CryptoService cryptoService;

  String? mnemonic;
  String? username; // The generated username
  String? displayName; // The custom display name
  String? bio; // The custom bio
  SimpleKeyPair? masterKeyPair;
  SimplePublicKey? masterPublicKey;
  String? masterPublicKeyHex;

  IdentityKeyPair? signalIdentityKeyPair;
  int? signalRegistrationId;

  bool get isAuthenticated => masterKeyPair != null;

  AuthProvider({required this.identityRepo, required this.cryptoService});

  Future<void> generateAndSaveIdentity() async {
    mnemonic = cryptoService.generateMnemonic();
    await identityRepo.saveMnemonic(mnemonic!);

    masterKeyPair = await cryptoService.generateMasterKeyPair(mnemonic!);
    masterPublicKey = await masterKeyPair!.extractPublicKey();
    username = await cryptoService.generateUsername(masterPublicKey!);
    masterPublicKeyHex = masterPublicKey!.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');

    signalIdentityKeyPair = generateIdentityKeyPair();
    signalRegistrationId = generateRegistrationId(false);
    await identityRepo.saveSignalIdentity(signalIdentityKeyPair!, signalRegistrationId!);

    NostrRelayService().initKeys(mnemonic!);
    await NostrRelayService().connectToRelays();

    notifyListeners();
  }

  Future<bool> restoreIdentity() async {
    final savedMnemonic = await identityRepo.getMnemonic();
    if (savedMnemonic != null) {
      mnemonic = savedMnemonic;
      masterKeyPair = await cryptoService.generateMasterKeyPair(mnemonic!);
      masterPublicKey = await masterKeyPair!.extractPublicKey();
      username = await cryptoService.generateUsername(masterPublicKey!);
      masterPublicKeyHex = masterPublicKey!.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');

      final (savedName, savedBio) = await identityRepo.getCustomProfile();
      displayName = savedName;
      bio = savedBio;

      final (savedSignalIdentity, savedRegId) = await identityRepo.getSignalIdentity();
      if (savedSignalIdentity != null && savedRegId != null) {
        signalIdentityKeyPair = savedSignalIdentity;
        signalRegistrationId = savedRegId;
      } else {
        print("Generating fresh Signal identity...");
        signalIdentityKeyPair = generateIdentityKeyPair();
        signalRegistrationId = generateRegistrationId(false);
        await identityRepo.saveSignalIdentity(signalIdentityKeyPair!, signalRegistrationId!);
      }

      NostrRelayService().initKeys(mnemonic!);
      await NostrRelayService().connectToRelays();

      notifyListeners();
      return true;
    }
    return false;
  }

  Future<bool> loginWithMnemonic(String inputMnemonic) async {
    try {
      await cryptoService.generateMasterKeyPair(inputMnemonic);
      await identityRepo.saveMnemonic(inputMnemonic);
      // Force fresh keys on login
      await identityRepo.clearAll();
      await identityRepo.saveMnemonic(inputMnemonic);
      
      final success = await restoreIdentity();
      return success;
    } catch (e) {
      print("Invalid mnemonic: $e");
      return false;
    }
  }

  Future<void> updateProfile(String? newDisplayName, String? newBio) async {
    displayName = newDisplayName?.trim().isEmpty == true ? null : newDisplayName?.trim();
    bio = newBio?.trim().isEmpty == true ? null : newBio?.trim();
    
    await identityRepo.saveCustomProfile(displayName, bio);
    
    
    final prefs = await SharedPreferences.getInstance();
    final String suffix = const String.fromEnvironment('INSTANCE', defaultValue: '1');
    final isAnnounced = prefs.getBool('is_announced_$suffix') ?? false;
    
    if (isAnnounced && masterPublicKeyHex != null && username != null) {
      NostrRelayService().broadcastProfile(
        masterPublicKeyHex!, 
        username: username!,
        displayName: displayName,
        bio: bio,
      );
    }
    
    notifyListeners();
  }

  Future<void> logout() async {
    await identityRepo.clearAll();
    mnemonic = null;
    username = null;
    displayName = null;
    bio = null;
    masterKeyPair = null;
    masterPublicKey = null;
    masterPublicKeyHex = null;
    signalIdentityKeyPair = null;
    signalRegistrationId = null;
    notifyListeners();
  }
}
