import 'dart:async';
import 'package:flutter/material.dart';
import '../../models/discover_user.dart';

class OnlineStatusIndicator extends StatefulWidget {
  final DiscoverUser user;
  
  const OnlineStatusIndicator({super.key, required this.user});

  @override
  State<OnlineStatusIndicator> createState() => _OnlineStatusIndicatorState();
}

class _OnlineStatusIndicatorState extends State<OnlineStatusIndicator> {
  Timer? _timer;
  late bool _wasOnline;

  @override
  void initState() {
    super.initState();
    _wasOnline = widget.user.isOnline;
    // Check every 2 seconds if the online status has flipped
    _timer = Timer.periodic(const Duration(seconds: 2), (timer) {
      final isNowOnline = widget.user.isOnline;
      if (isNowOnline != _wasOnline && mounted) {
        setState(() {
          _wasOnline = isNowOnline;
        });
      }
    });
  }

  @override
  void didUpdateWidget(OnlineStatusIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.user.isOnline != _wasOnline) {
      setState(() {
        _wasOnline = widget.user.isOnline;
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        color: widget.user.isOnline ? Colors.green : Colors.grey,
        shape: BoxShape.circle,
        border: Border.all(color: Theme.of(context).scaffoldBackgroundColor, width: 2),
      ),
    );
  }
}
