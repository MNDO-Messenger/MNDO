import 'dart:async';
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

  Future<void>? identityInitFuture;

  AuthProvider({required this.identityRepo, required this.cryptoService});

  void resetOnboarding() {
    mnemonic = null;
    masterKeyPair = null;
    masterPublicKey = null;
    username = null;
    masterPublicKeyHex = null;
    signalIdentityKeyPair = null;
    signalRegistrationId = null;
    notifyListeners();
  }

  Future<void> generateAndSaveIdentity() async {
    mnemonic = cryptoService.generateMnemonic();
    notifyListeners(); // UI transitions immediately with zero frame drop or lag!

    identityInitFuture = _deriveAndPersistKeys(mnemonic!);
    await identityInitFuture;
  }

  Future<void> _deriveAndPersistKeys(String phrase) async {
    final derivedMasterKeyPair = await cryptoService.generateMasterKeyPair(phrase);
    if (mnemonic != phrase) return; // User cancelled onboarding or went back

    await identityRepo.saveMnemonic(phrase);
    if (mnemonic != phrase) return;

    masterKeyPair = derivedMasterKeyPair;
    masterPublicKey = await masterKeyPair!.extractPublicKey();
    username = await cryptoService.generateUsername(masterPublicKey!);
    masterPublicKeyHex = masterPublicKey!.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');

    signalIdentityKeyPair = generateIdentityKeyPair();
    signalRegistrationId = generateRegistrationId(false);
    await identityRepo.saveSignalIdentity(signalIdentityKeyPair!, signalRegistrationId!);

    if (mnemonic != phrase) return;

    NostrRelayService().initKeys(phrase);
    await NostrRelayService().connectToRelays();

    if (mnemonic != phrase) return;
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

  bool validateMnemonic(String phrase) {
    return cryptoService.validateMnemonic(phrase);
  }

  Future<bool> loginWithMnemonic(String inputMnemonic) async {
    try {
      final cleanMnemonic = inputMnemonic.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
      if (!cryptoService.validateMnemonic(cleanMnemonic)) {
        print("Invalid BIP-39 mnemonic phrase or checksum failed");
        return false;
      }
      await cryptoService.generateMasterKeyPair(cleanMnemonic);
      // Force fresh keys on login
      await identityRepo.clearAll();
      await identityRepo.saveMnemonic(cleanMnemonic);
      
      final success = await restoreIdentity();
      return success;
    } catch (e) {
      print("Invalid mnemonic: $e");
      return false;
    }
  }

  /// Target #4: Cryptographically bind public presence and Nostr session using Master Ed25519 signature
  Future<String?> createDelegationSignature(String nostrPubKeyHex, int timestamp) async {
    if (masterKeyPair == null) return null;
    return await cryptoService.signDelegationToken(
      masterKeyPair: masterKeyPair!,
      nostrPubKeyHex: nostrPubKeyHex,
      timestamp: timestamp,
    );
  }

  Future<void> updateProfile(String? newDisplayName, String? newBio) async {
    displayName = newDisplayName?.trim().isEmpty == true ? null : newDisplayName?.trim();
    bio = newBio?.trim().isEmpty == true ? null : newBio?.trim();
    
    await identityRepo.saveCustomProfile(displayName, bio);
    
    final prefs = await SharedPreferences.getInstance();
    final String suffix = const String.fromEnvironment('INSTANCE', defaultValue: '1');
    final String masterKey = masterPublicKeyHex ?? '';
    final isAnnounced = (masterKey.isNotEmpty ? prefs.getBool('is_announced_${masterKey}_$suffix') : null)
        ?? prefs.getBool('is_announced_$suffix')
        ?? false;
    
    if (masterPublicKeyHex != null) {
      if (username != null) {
        NostrRelayService().broadcastProfileMetadata(
          username!,
          masterPublicKeyHex!,
          displayName: displayName,
          bio: bio,
        );
      }
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final sig = await createDelegationSignature(NostrRelayService().publicHex, nowMs);
      NostrRelayService().broadcastPing(
        masterPublicKeyHex!,
        isOnline: true,
        isHidden: !isAnnounced,
        username: username,
        displayName: displayName,
        bio: bio,
        masterSig: sig,
        timestampMs: nowMs,
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
