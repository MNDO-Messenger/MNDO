import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/discover_provider.dart';
import '../providers/chat_provider.dart';
import '../database/database.dart';
import 'onboarding_screen.dart';
import 'qr_settings_screen.dart';
import 'widgets/identicon.dart';

import 'settings_screen.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  void _showEditProfileDialog(BuildContext context, AuthProvider appState) {
    final nameController = TextEditingController(text: appState.displayName ?? '');
    final bioController = TextEditingController(text: appState.bio ?? '');

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Edit Profile'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: 'Display Name',
                  hintText: 'e.g. Satoshi Nakamoto',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: bioController,
                decoration: const InputDecoration(
                  labelText: 'Bio',
                  hintText: 'A bit about yourself...',
                ),
                maxLines: 3,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                appState.updateProfile(nameController.text, bioController.text);
                Navigator.pop(context);
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AuthProvider>();
    final discoverState = context.watch<DiscoverProvider>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('My Profile'),
        actions: [
          IconButton(
            icon: const Icon(Icons.qr_code_scanner),
            tooltip: 'QR Code',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const QRSettingsScreen()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const SettingsScreen()),
              );
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(height: 20),
              
              // Profile Avatar
              if (appState.masterPublicKeyHex != null)
                Identicon(
                  seed: appState.masterPublicKeyHex!,
                  size: 100,
                )
              else
                CircleAvatar(
                  radius: 50,
                  backgroundColor: const Color(0xFF6366F1).withOpacity(0.1),
                  child: const Icon(Icons.person, size: 50, color: Color(0xFF6366F1)),
                ),
              
              const SizedBox(height: 20),
              Text(
                appState.displayName ?? appState.username ?? 'Unknown Identity',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              if (appState.displayName != null && appState.displayName!.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  '@${appState.username}',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.grey,
                  ),
                ),
              ],
              if (appState.bio != null && appState.bio!.isNotEmpty) ...[
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24.0),
                  child: Text(
                    appState.bio!,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              OutlinedButton.icon(
                icon: const Icon(Icons.edit, size: 18),
                label: const Text('Edit Profile'),
                onPressed: () => _showEditProfileDialog(context, appState),
              ),
              const SizedBox(height: 40),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Your Public Key (Share this to chat privately):',
                  style: TextStyle(color: Colors.grey),
                ),
              ),
              const SizedBox(height: 8),
              
              // Public Key Box with Copy Button
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Theme.of(context).cardTheme.color,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Theme.of(context).colorScheme.outlineVariant ?? const Color(0xFFE4E4E7)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        appState.masterPublicKeyHex ?? 'No key available',
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy),
                      tooltip: 'Copy Public Key',
                      onPressed: () {
                        if (appState.masterPublicKeyHex != null) {
                          Clipboard.setData(ClipboardData(text: appState.masterPublicKeyHex!));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Public Key copied to clipboard!')),
                          );
                        }
                      },
                    ),
                  ],
                ),
              ),
              
              const SizedBox(height: 40),
              const Divider(),
              const SizedBox(height: 20),
              
              // Announce Me Section
              if (!discoverState.isAnnounced) ...[
                const Text(
                  'Want to find random users?',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                const Text(
                  'By clicking Announce Me, your Public Key will be broadcast to the public Nostr feed so anyone can discover and message you.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: () {
                    discoverState.announcePresence();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('You are now public! Sending online pings...')),
                    );
                  },
                  icon: const Icon(Icons.campaign),
                  label: const Text('Announce Me to the Public Feed'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF10B981), // Emerald green
                    foregroundColor: Colors.white,
                  ),
                ),
              ] else ...[
                const Icon(Icons.public, color: Colors.green, size: 32),
                const SizedBox(height: 8),
                const Text(
                  'You are public on the Discover Feed',
                  style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: () {
                    discoverState.stopHeartbeat();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('You are now hidden from the public feed.')),
                    );
                  },
                  icon: const Icon(Icons.visibility_off),
                  label: const Text('Stop Announcing'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.grey.shade800,
                    foregroundColor: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Your online status is visible to others.',
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
