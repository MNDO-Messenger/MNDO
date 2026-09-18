import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/providers.dart';

class AppearanceScreen extends ConsumerWidget {
  const AppearanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeProvider = ref.watch(themeNotifierProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Appearance'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Theme',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ),
            const SizedBox(height: 12),
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                borderRadius: BorderRadius.circular(16),
                color: Theme.of(context).cardTheme.color,
              ),
              child: Column(
                children: [
                  RadioListTile<ThemeMode>(
                    title: const Text('Light'),
                    value: ThemeMode.light,
                    groupValue: themeProvider.themeMode,
                    onChanged: (ThemeMode? value) {
                      if (value != null) {
                        themeProvider.setThemeMode(value);
                      }
                    },
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  RadioListTile<ThemeMode>(
                    title: const Text('Dark'),
                    value: ThemeMode.dark,
                    groupValue: themeProvider.themeMode,
                    onChanged: (ThemeMode? value) {
                      if (value != null) {
                        themeProvider.setThemeMode(value);
                      }
                    },
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  RadioListTile<ThemeMode>(
                    title: const Text('System Default'),
                    value: ThemeMode.system,
                    groupValue: themeProvider.themeMode,
                    onChanged: (ThemeMode? value) {
                      if (value != null) {
                        themeProvider.setThemeMode(value);
                      }
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
