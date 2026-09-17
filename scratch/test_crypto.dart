import 'package:cryptography/cryptography.dart';
import '../lib/services/crypto_service.dart';
import '../lib/core/dictionary.dart';

void main() async {
  final crypto = CryptoService();
  final hexStr = '029a69e26b7d7360e210cdee1386bb0eebbfa5ca52354afc7e7cb35f02c7967e';
  
  final bytes = <int>[];
  for (int i = 0; i < hexStr.length; i += 2) {
    bytes.add(int.parse(hexStr.substring(i, i + 2), radix: 16));
  }
  
  final pubKey = SimplePublicKey(bytes, type: KeyPairType.ed25519);
  try {
    final username = await crypto.generateUsername(pubKey);
    print('Generated: \$username');
  } catch (e) {
    print('Error: \$e');
  }
}
