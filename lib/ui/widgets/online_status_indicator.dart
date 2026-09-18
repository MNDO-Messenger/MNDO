import 'package:flutter/material.dart';
import '../../models/discover_user.dart';

class OnlineStatusIndicator extends StatelessWidget {
  final DiscoverUser user;
  
  const OnlineStatusIndicator({super.key, required this.user});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        color: user.isOnline ? Colors.green : Colors.grey,
        shape: BoxShape.circle,
        border: Border.all(color: Theme.of(context).scaffoldBackgroundColor, width: 2),
      ),
    );
  }
}

