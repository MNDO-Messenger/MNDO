import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/discover_provider.dart';
import '../providers/chat_provider.dart';
import '../database/database.dart';
import 'onboarding_screen.dart';
import 'appearance_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'General',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ),
            const SizedBox(height: 12),
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).colorScheme.outlineVariant ?? const Color(0xFFE4E4E7)),
                borderRadius: BorderRadius.circular(16),
                color: Theme.of(context).cardTheme.color,
              ),
              child: ListTile(
                title: const Text('Appearance'),
                subtitle: const Text('Dark mode, light mode'),
                leading: const Icon(Icons.palette),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const AppearanceScreen()),
                  );
                },
              ),
            ),
            
            const SizedBox(height: 40),
            
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Danger Zone',
                style: TextStyle(color: Color(0xFFEF4444), fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ),
            const SizedBox(height: 12),
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).colorScheme.outlineVariant ?? const Color(0xFFE4E4E7)),
                borderRadius: BorderRadius.circular(16),
                color: Theme.of(context).cardTheme.color,
              ),
              child: ListTile(
                title: const Text('Wipe Data & Logout', style: TextStyle(color: Color(0xFFEF4444), fontWeight: FontWeight.bold)),
                subtitle: const Text('Permanently deletes your keys from this device.', style: TextStyle(color: Colors.grey, fontSize: 12)),
                trailing: const Icon(Icons.delete_forever, color: Color(0xFFEF4444)),
                onTap: () {
                  _showLogoutDialog(context);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showLogoutDialog(BuildContext context) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Log Out?'),
        content: const Text('This will clear your local chats and keys. Make sure you have your 12-word phrase backed up!'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFEF4444)),
            child: const Text('Log Out'),
          ),
        ],
      ),
    );
    
    if (confirm == true && context.mounted) {
      await context.read<DiscoverProvider>().logout();
      await context.read<ChatProvider>().clearAll();
      await context.read<AuthProvider>().logout();
      
      await context.read<AppDatabase>().clearSignalData();
      
      if (context.mounted) {
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (context) => const OnboardingScreen()),
          (route) => false,
        );
      }
    }
  }
}
