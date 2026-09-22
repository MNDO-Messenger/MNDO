import 'package:flutter/material.dart';
import '../../models/discover_user.dart';

class OnlineStatusIndicator extends StatelessWidget {
  final DiscoverUser user;
  final double size;
  
  const OnlineStatusIndicator({
    super.key, 
    required this.user, 
    this.size = 14.0,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isOnline = user.isOnline;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: isOnline
            ? const Color(0xFF4BD151) // Luminous high-visibility emerald green
            : (isDark ? const Color(0xFF52525B) : const Color(0xFF9CA3AF)), // Distinct muted offline slate
        shape: BoxShape.circle,
        border: Border.all(
          color: Theme.of(context).scaffoldBackgroundColor,
          width: 2.0,
        ),
        boxShadow: isOnline
            ? [
                BoxShadow(
                  color: const Color(0xFF4BD151).withValues(alpha: isDark ? 0.60 : 0.40),
                  blurRadius: 5,
                  spreadRadius: 0.5,
                ),
              ]
            : null,
      ),
    );
  }
}

