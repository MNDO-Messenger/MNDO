import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../core/providers.dart';
import '../services/nostr_relay_service.dart';
import 'chat_screen.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

class QRSettingsScreen extends ConsumerStatefulWidget {
  const QRSettingsScreen({super.key});

  @override
  ConsumerState<QRSettingsScreen> createState() => _QRSettingsScreenState();
}

class _QRSettingsScreenState extends ConsumerState<QRSettingsScreen> with SingleTickerProviderStateMixin {
  TabController? _tabController;
  MobileScannerController? _scannerController;
  bool _isProcessing = false;

  bool get _isDesktop => !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  @override
  void initState() {
    super.initState();
    if (!_isDesktop) {
      _tabController = TabController(length: 2, vsync: this);
      _scannerController = MobileScannerController();
    }
  }

  @override
  void dispose() {
    _tabController?.dispose();
    _scannerController?.dispose();
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
        final mPubKey = parts[0].trim();
        final nPubKey = parts[1].trim();
        
        if (mPubKey.length >= 64 && nPubKey.length >= 64) {
          setState(() => _isProcessing = true);
          
          final authProvider = ref.read(authNotifierProvider);
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
      _isProcessing = true;
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) setState(() => _isProcessing = false);
      });
    }
  }

  Widget _buildMyCodeView(BuildContext context, dynamic authProvider) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
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
                      color: Colors.black.withValues(alpha: 0.05),
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
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Text(
                'Let friends scan this code from their MNDO app to start a private chat with you.',
                textAlign: TextAlign.center,
                style: TextStyle(color: isDark ? const Color(0xFFA1A1AA) : Colors.grey),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScannerView() {
    if (_scannerController == null) return const SizedBox.shrink();
    return Stack(
      children: [
        MobileScanner(
          controller: _scannerController!,
          onDetect: _onDetect,
        ),
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final authProvider = ref.watch(authNotifierProvider);

    if (_isDesktop) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('My QR Code'),
        ),
        body: _buildMyCodeView(context, authProvider),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('QR Code'),
        bottom: _tabController != null
            ? TabBar(
                controller: _tabController,
                tabs: const [
                  Tab(text: 'My Code'),
                  Tab(text: 'Scan Code'),
                ],
              )
            : null,
      ),
      body: _tabController != null
          ? TabBarView(
              controller: _tabController,
              children: [
                _buildMyCodeView(context, authProvider),
                _buildScannerView(),
              ],
            )
          : _buildMyCodeView(context, authProvider),
    );
  }
}
