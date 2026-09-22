import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/providers.dart';
import '../providers/auth_provider.dart';
import 'qr_settings_screen.dart';
import 'settings_screen.dart';
import 'widgets/identicon.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  bool _copiedKey = false;
  Timer? _copyTimer;

  @override
  void dispose() {
    _copyTimer?.cancel();
    super.dispose();
  }

  void _copyPublicKey(String publicKeyHex) {
    Clipboard.setData(ClipboardData(text: publicKeyHex));
    HapticFeedback.lightImpact();
    setState(() {
      _copiedKey = true;
    });

    _copyTimer?.cancel();
    _copyTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() {
          _copiedKey = false;
        });
      }
    });

    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Row(
          children: [
            Icon(Icons.check_circle_rounded, color: Colors.white, size: 18),
            SizedBox(width: 10),
            Text('Public Key copied to clipboard'),
          ],
        ),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _showEditProfileDialog(BuildContext context, AuthProvider appState) {
    final nameController = TextEditingController(text: appState.displayName ?? '');
    final bioController = TextEditingController(text: appState.bio ?? '');

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text(
            'Edit Profile',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: InputDecoration(
                  labelText: 'Display Name',
                  hintText: 'e.g. Satoshi Nakamoto',
                  filled: true,
                  fillColor: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Theme.of(context).dividerColor.withValues(alpha: 0.1)),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: bioController,
                decoration: InputDecoration(
                  labelText: 'Bio',
                  hintText: 'A bit about yourself...',
                  filled: true,
                  fillColor: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Theme.of(context).dividerColor.withValues(alpha: 0.1)),
                  ),
                ),
                maxLines: 3,
              ),
            ],
          ),
          actionsPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                appState.updateProfile(nameController.text, bioController.text);
                Navigator.pop(context);
              },
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final appState = ref.watch(authNotifierProvider);
    final discoverState = ref.watch(discoverNotifierProvider);
    final hasAnnounced = discoverState.hasEverAnnounced || discoverState.isAnnounced;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Profile',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.qr_code_2_rounded),
            tooltip: 'QR Code',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const QRSettingsScreen()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const SettingsScreen()),
              );
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const SizedBox(height: 12),

                // Profile Avatar with subtle halo and presence badge
                Stack(
                  alignment: Alignment.bottomRight,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: const Color(0xFF6366F1).withValues(alpha: 0.25),
                          width: 2.5,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF6366F1).withValues(alpha: 0.08),
                            blurRadius: 24,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      child: appState.masterPublicKeyHex != null
                          ? Identicon(
                              seed: appState.masterPublicKeyHex!,
                              size: 96,
                            )
                          : CircleAvatar(
                              radius: 48,
                              backgroundColor: const Color(0xFF6366F1).withValues(alpha: 0.1),
                              child: const Icon(
                                Icons.person_rounded,
                                size: 48,
                                color: Color(0xFF6366F1),
                              ),
                            ),
                    ),
                    if (discoverState.isAnnounced)
                      Positioned(
                        right: 4,
                        bottom: 4,
                        child: Container(
                          width: 18,
                          height: 18,
                          decoration: BoxDecoration(
                            color: const Color(0xFF10B981),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Theme.of(context).scaffoldBackgroundColor,
                              width: 3,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),

                const SizedBox(height: 18),

                // Display Name
                Text(
                  appState.displayName ?? appState.username ?? 'Unknown Identity',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.4,
                      ),
                  textAlign: TextAlign.center,
                ),

                // Username handle badge
                if (appState.username != null && appState.username!.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      '@${appState.username}',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                ],

                // Bio
                if (appState.bio != null && appState.bio!.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20.0),
                    child: Text(
                      appState.bio!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.45,
                        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.75),
                      ),
                    ),
                  ),
                ],

                const SizedBox(height: 24),

                // Minimalist Action Buttons Row (Edit Profile + Copy Public Key)
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 12,
                  runSpacing: 10,
                  children: [
                    OutlinedButton.icon(
                      icon: const Icon(Icons.edit_outlined, size: 16),
                      label: const Text('Edit Profile'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        side: BorderSide(
                          color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.7),
                        ),
                      ),
                      onPressed: () => _showEditProfileDialog(context, appState),
                    ),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: OutlinedButton.icon(
                        key: ValueKey<bool>(_copiedKey),
                        icon: Icon(
                          _copiedKey ? Icons.check_rounded : Icons.copy_rounded,
                          size: 16,
                          color: _copiedKey ? const Color(0xFF10B981) : null,
                        ),
                        label: Text(
                          _copiedKey ? 'Key Copied' : 'Copy Public Key',
                          style: TextStyle(
                            color: _copiedKey ? const Color(0xFF10B981) : null,
                            fontWeight: _copiedKey ? FontWeight.bold : FontWeight.w500,
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          side: BorderSide(
                            color: _copiedKey
                                ? const Color(0xFF10B981)
                                : Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.7),
                            width: _copiedKey ? 1.5 : 1.0,
                          ),
                        ),
                        onPressed: appState.masterPublicKeyHex == null
                            ? null
                            : () => _copyPublicKey(appState.masterPublicKeyHex!),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 36),
                Divider(
                  color: Theme.of(context).dividerColor.withValues(alpha: 0.08),
                  height: 1,
                ),
                const SizedBox(height: 28),

                // Announce / Discover Section: Seamless button-to-toggle flow
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  transitionBuilder: (child, animation) {
                    return FadeTransition(
                      opacity: animation,
                      child: child,
                    );
                  },
                  child: !hasAnnounced
                      ? Center(
                          key: const ValueKey('announce_button'),
                          child: FilledButton.icon(
                            onPressed: () {
                              discoverState.announcePresence();
                              ScaffoldMessenger.of(context).clearSnackBars();
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: const Row(
                                    children: [
                                      Icon(Icons.sensors_rounded, color: Colors.white, size: 18),
                                      SizedBox(width: 10),
                                      Text('Discoverable on Public Feed'),
                                    ],
                                  ),
                                  behavior: SnackBarBehavior.floating,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                  duration: const Duration(seconds: 2),
                                ),
                              );
                            },
                            icon: const Icon(Icons.podcasts_rounded, size: 18),
                            label: const Text('Announce Me to the Public Feed'),
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFF10B981),
                              foregroundColor: Colors.white,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                              textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                            ),
                          ),
                        )
                      : Container(
                          key: const ValueKey('announce_toggle'),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: Theme.of(context).dividerColor.withValues(alpha: 0.08),
                            ),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: (discoverState.isAnnounced
                                          ? const Color(0xFF10B981)
                                          : Colors.grey)
                                      .withValues(alpha: 0.12),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  discoverState.isAnnounced
                                      ? Icons.sensors_rounded
                                      : Icons.sensors_off_rounded,
                                  color: discoverState.isAnnounced
                                      ? const Color(0xFF10B981)
                                      : Colors.grey,
                                  size: 20,
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Text(
                                      'Discoverable on Public Feed',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                        fontSize: 14,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      discoverState.isAnnounced
                                          ? 'Visible to other users'
                                          : 'Hidden from public feed',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: discoverState.isAnnounced
                                            ? const Color(0xFF10B981)
                                            : Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.65),
                                        fontWeight: discoverState.isAnnounced
                                            ? FontWeight.w500
                                            : FontWeight.normal,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Switch.adaptive(
                                value: discoverState.isAnnounced,
                                activeTrackColor: const Color(0xFF10B981),
                                onChanged: (val) {
                                  if (val) {
                                    discoverState.announcePresence();
                                    ScaffoldMessenger.of(context).clearSnackBars();
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: const Row(
                                          children: [
                                            Icon(Icons.sensors_rounded, color: Colors.white, size: 18),
                                            SizedBox(width: 10),
                                            Text('Discoverable on Public Feed'),
                                          ],
                                        ),
                                        behavior: SnackBarBehavior.floating,
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                        duration: const Duration(seconds: 2),
                                      ),
                                    );
                                  } else {
                                    discoverState.stopHeartbeat();
                                    ScaffoldMessenger.of(context).clearSnackBars();
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: const Row(
                                          children: [
                                            Icon(Icons.sensors_off_rounded, color: Colors.white, size: 18),
                                            SizedBox(width: 10),
                                            Text('Hidden from public feed'),
                                          ],
                                        ),
                                        behavior: SnackBarBehavior.floating,
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                        duration: const Duration(seconds: 2),
                                      ),
                                    );
                                  }
                                },
                              ),
                            ],
                          ),
                        ),
                ),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
