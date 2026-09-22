import 'package:bip39/bip39.dart' as bip39;
import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart';
import '../core/dictionary.dart';

class CryptoService {
  final _ed25519 = Ed25519();
  
  // Uses appAdjectives and appNouns from dictionary.dart

  /// Generates a 12-word BIP-39 mnemonic
  String generateMnemonic() {
    return bip39.generateMnemonic();
  }

  /// Validates if the mnemonic adheres to the BIP-39 standard (valid dictionary words and valid checksum)
  bool validateMnemonic(String mnemonic) {
    final clean = mnemonic.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    if (clean.split(' ').where((w) => w.isNotEmpty).length != 12) return false;
    return bip39.validateMnemonic(clean);
  }

  /// Derives an Ed25519 Master KeyPair from the mnemonic
  Future<SimpleKeyPair> generateMasterKeyPair(String mnemonic) async {
    final seed = bip39.mnemonicToSeed(mnemonic);
    // Ed25519 requires a 32-byte seed, but bip39 gives 64 bytes.
    // We take the first 32 bytes.
    final seed32 = seed.sublist(0, 32);
    
    return await _ed25519.newKeyPairFromSeed(seed32);
  }

  /// Generates the deterministic username from the public key
  Future<String> generateUsername(SimplePublicKey publicKey) async {
    // Hash the public key bytes using SHA-256 for deterministic distribution
    final hash = sha256.convert(publicKey.bytes);
    final hashBytes = hash.bytes;
    
    // Convert first few bytes to integers to pick adjective and noun
    int adjIndex = ((hashBytes[0] << 8) | hashBytes[1]) % appAdjectives.length;
    int nounIndex = ((hashBytes[2] << 8) | hashBytes[3]) % appNouns.length;
    
    final adjective = appAdjectives[adjIndex];
    final noun = appNouns[nounIndex];
    
    // Generate a 6-character hex suffix from bytes 4, 5, and 6 for 16.7 trillion combinations
    final hexSuffix = '${hashBytes[4].toRadixString(16).padLeft(2, '0')}${hashBytes[5].toRadixString(16).padLeft(2, '0')}${hashBytes[6].toRadixString(16).padLeft(2, '0')}';
    
    return '$adjective $noun #$hexSuffix';
  }
}
