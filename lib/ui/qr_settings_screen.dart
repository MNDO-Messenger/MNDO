import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
import '../services/nostr_relay_service.dart';
import 'chat_screen.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

class QRSettingsScreen extends StatefulWidget {
  const QRSettingsScreen({super.key});

  @override
  State<QRSettingsScreen> createState() => _QRSettingsScreenState();
}

class _QRSettingsScreenState extends State<QRSettingsScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final MobileScannerController _scannerController = MobileScannerController();
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _scannerController.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_isProcessing) return;
    
    final List<Barcode> barcodes = capture.barcodes;
    if (barcodes.isNotEmpty) {
      final String? rawCode = barcodes.first.rawValue;
      if (rawCode != null && rawCode.contains(':')) {
        final code = rawCode.trim();
        final parts = code.split(':');
        // Let's trim parts just in case
        final mPubKey = parts[0].trim();
        final nPubKey = parts[1].trim();
        
        if (mPubKey.length >= 64 && nPubKey.length >= 64) {
          
          setState(() => _isProcessing = true);
          
          // Start a chat!
          final authProvider = context.read<AuthProvider>();
          if (mPubKey == authProvider.masterPublicKeyHex) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('You cannot chat with yourself!')),
            );
            Future.delayed(const Duration(seconds: 2), () {
              if (mounted) setState(() => _isProcessing = false);
            });
            return;
          }

          Navigator.pop(context); // Close QR screen
          Navigator.pop(context); // Close Settings screen
          
          // Navigate to chat
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => ChatScreen(
                recipientMasterPubKey: mPubKey,
                recipientNostrPubKey: nPubKey,
                recipientUsername: 'Unknown Scanned User',
              ),
            ),
          );
          return;
        }
      }
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Invalid QR Code. Scanned: ${barcodes.first.rawValue}')),
      );
      // Wait before scanning again
      _isProcessing = true;
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) setState(() => _isProcessing = false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final authProvider = context.watch<AuthProvider>();
    final isDesktop = !kIsWeb && (Platform.isWindows || Platform.isLinux);

    return Scaffold(
      appBar: AppBar(
        title: const Text('QR Code'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'My Code'),
            Tab(text: 'Scan Code'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          // TAB 1: My Code
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (authProvider.masterPublicKeyHex != null)
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.05),
                          blurRadius: 20,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: QrImageView(
                      data: "${authProvider.masterPublicKeyHex!}:${NostrRelayService().publicHex}",
                      version: QrVersions.auto,
                      size: 250.0,
                    ),
                  ),
                const SizedBox(height: 32),
                const Text(
                  'Your QR Code',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 40),
                  child: Text(
                    'Let friends scan this code from their MNDO app to start a private chat with you.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
              ],
            ),
          ),
          
          // TAB 2: Scan Code
          isDesktop
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.desktop_access_disabled, size: 64, color: Colors.grey),
                        SizedBox(height: 16),
                        Text(
                          'Camera scanning is not supported on desktop.',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 18, color: Colors.grey),
                        ),
                        SizedBox(height: 8),
                        Text(
                          'Please ask your friend to copy and send you their Public Key text directly.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                )
              : Stack(
                  children: [
                    MobileScanner(
                      controller: _scannerController,
                      onDetect: _onDetect,
                    ),
                    // Optional: A targeting overlay
                    Center(
                      child: Container(
                        width: 250,
                        height: 250,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.white, width: 2),
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                    ),
                    const Positioned(
                      bottom: 40,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: Text(
                          'Align QR code within the frame',
                          style: TextStyle(color: Colors.white, fontSize: 16, backgroundColor: Colors.black54),
                        ),
                      ),
                    ),
                  ],
                ),
        ],
      ),
    );
  }
}
