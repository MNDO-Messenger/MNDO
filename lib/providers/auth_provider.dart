import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:cryptography/cryptography.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import '../repositories/identity_repository.dart';
import '../services/crypto_service.dart';
import '../services/nostr_relay_service.dart';
import '../services/account_session.dart';
import '../database/database.dart';
import '../services/signal_messaging_service.dart';
import 'chat_provider.dart';
import 'discover_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AuthProvider extends ChangeNotifier {
  final IdentityRepository identityRepo;
  final CryptoService cryptoService;
  final NostrRelayService? nostrService;

  NostrRelayService get _nostr => nostrService ?? NostrRelayService();

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

  AuthProvider({
    required this.identityRepo,
    required this.cryptoService,
    this.nostrService,
  });

  void resetOnboarding() {
    mnemonic = null;
    masterKeyPair = null;
    masterPublicKey = null;
    username = null;
    masterPublicKeyHex = null;
    signalIdentityKeyPair = null;
    signalRegistrationId = null;
    identityRepo.clearAll();
    notifyListeners();
  }

  Future<void> generateAndSaveIdentity() async {
    mnemonic = cryptoService.generateMnemonic();
    notifyListeners(); // UI transitions immediately with zero frame drop or lag!

    identityInitFuture = _deriveAndPersistKeys(mnemonic!);
    await identityInitFuture;
  }

  Future<void> _deriveAndPersistKeys(String phrase) {
    return AccountSession.synchronize(() async {
      final sessionGen = AccountSession.currentGeneration;
      final derivedMasterKeyPair = await cryptoService.generateMasterKeyPair(phrase);
      if (mnemonic != phrase || !AccountSession.isGenerationValid(sessionGen)) return;

      await identityRepo.saveMnemonic(phrase);
      if (mnemonic != phrase || !AccountSession.isGenerationValid(sessionGen)) return;

      masterKeyPair = derivedMasterKeyPair;
      masterPublicKey = await masterKeyPair!.extractPublicKey();
      username = await cryptoService.generateUsername(masterPublicKey!);
      masterPublicKeyHex = masterPublicKey!.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');

      signalIdentityKeyPair = generateIdentityKeyPair();
      signalRegistrationId = generateRegistrationId(false);
      await identityRepo.saveSignalIdentity(signalIdentityKeyPair!, signalRegistrationId!);

      if (mnemonic != phrase || !AccountSession.isGenerationValid(sessionGen)) return;

      final newGen = AccountSession.startNewSession();
      _nostr.initKeys(phrase, sessionGeneration: newGen);
      await _nostr.connectToRelays();

      if (mnemonic != phrase || !AccountSession.isGenerationValid(newGen)) return;
      notifyListeners();
    });
  }

  Future<bool> restoreIdentity() {
    return AccountSession.synchronize(() async {
      final originatingGen = AccountSession.currentGeneration;
      if (!AccountSession.isGenerationValid(originatingGen)) return false;

      final savedMnemonic = await identityRepo.getMnemonic();
      if (!AccountSession.isGenerationValid(originatingGen)) return false;

      if (savedMnemonic != null) {
        final derivedMaster = await cryptoService.generateMasterKeyPair(savedMnemonic);
        if (!AccountSession.isGenerationValid(originatingGen)) return false;

        final pubKey = await derivedMaster.extractPublicKey();
        final user = await cryptoService.generateUsername(pubKey);
        final pubKeyHex = pubKey.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');

        final (savedName, savedBio) = await identityRepo.getCustomProfile();
        if (!AccountSession.isGenerationValid(originatingGen)) return false;

        final (savedSignalIdentity, savedRegId) = await identityRepo.getSignalIdentity();
        if (!AccountSession.isGenerationValid(originatingGen)) return false;

        IdentityKeyPair finalSignalIdentity;
        int finalRegId;
        if (savedSignalIdentity != null && savedRegId != null) {
          finalSignalIdentity = savedSignalIdentity;
          finalRegId = savedRegId;
        } else {
          print("Generating fresh Signal identity...");
          finalSignalIdentity = generateIdentityKeyPair();
          finalRegId = generateRegistrationId(false);
          await identityRepo.saveSignalIdentity(finalSignalIdentity, finalRegId);
          if (!AccountSession.isGenerationValid(originatingGen)) return false;
        }

        mnemonic = savedMnemonic;
        masterKeyPair = derivedMaster;
        masterPublicKey = pubKey;
        username = user;
        masterPublicKeyHex = pubKeyHex;
        displayName = savedName;
        bio = savedBio;
        signalIdentityKeyPair = finalSignalIdentity;
        signalRegistrationId = finalRegId;

        final newGen = AccountSession.startNewSession();
        _nostr.initKeys(mnemonic!, sessionGeneration: newGen);
        await _nostr.connectToRelays();

        if (!AccountSession.isGenerationValid(newGen)) return false;

        notifyListeners();
        return true;
      }
      return false;
    });
  }

  bool validateMnemonic(String phrase) {
    return cryptoService.validateMnemonic(phrase);
  }

  Future<bool> loginWithMnemonic(String inputMnemonic) {
    return AccountSession.synchronize(() async {
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
    });
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
    final sessionGen = AccountSession.currentGeneration;
    if (!AccountSession.isGenerationValid(sessionGen)) return;
    displayName = newDisplayName?.trim().isEmpty == true ? null : newDisplayName?.trim();
    bio = newBio?.trim().isEmpty == true ? null : newBio?.trim();
    
    await identityRepo.saveCustomProfile(displayName, bio);
    if (!AccountSession.isGenerationValid(sessionGen)) return;
    
    final prefs = await SharedPreferences.getInstance();
    final String suffix = const String.fromEnvironment('INSTANCE', defaultValue: '1');
    final String masterKey = masterPublicKeyHex ?? '';
    final isAnnounced = (masterKey.isNotEmpty ? prefs.getBool('is_announced_${masterKey}_$suffix') : null)
        ?? prefs.getBool('is_announced_$suffix')
        ?? false;
    
    if (masterPublicKeyHex != null) {
      if (username != null) {
        await NostrRelayService().broadcastProfileMetadata(
          username!,
          masterPublicKeyHex!,
          displayName: displayName,
          bio: bio,
          sessionGen: sessionGen,
        );
      }
      if (!AccountSession.isGenerationValid(sessionGen)) return;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final sig = await createDelegationSignature(NostrRelayService().publicHex, nowMs);
      if (!AccountSession.isGenerationValid(sessionGen)) return;
      await NostrRelayService().broadcastPing(
        masterPublicKeyHex!,
        isOnline: true,
        isHidden: !isAnnounced,
        username: username,
        displayName: displayName,
        bio: bio,
        masterSig: sig,
        timestampMs: nowMs,
        sessionGen: sessionGen,
      );
    }
    
    notifyListeners();
  }

  Future<void> clearCredentialsOnly({int? expectedGeneration}) async {
    if (expectedGeneration != null) {
      if (AccountSession.currentGeneration != expectedGeneration &&
          AccountSession.currentGeneration != expectedGeneration + 1) {
        print('[AUTH] Rejecting stale clearCredentialsOnly for gen $expectedGeneration (current: ${AccountSession.currentGeneration})');
        return;
      }
    }
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

  Future<void> logout({
    ChatProvider? chatProvider,
    DiscoverProvider? discoverProvider,
    SignalMessagingService? signalService,
    NostrRelayService? nostrService,
    AppDatabase? database,
  }) async {
    await AccountSession.dispose(
      authProvider: this,
      chatProvider: chatProvider,
      discoverProvider: discoverProvider,
      signalService: signalService,
      nostrService: nostrService,
      database: database,
    );
  }
}
