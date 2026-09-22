import 'package:flutter/material.dart';

/// Renders a contact's display name or auto-generated username.
///
/// When a custom [displayName] is present, it renders normally with [baseStyle].
/// When [displayName] is null or empty, it renders [username]. If [username]
/// contains an auto-generated hex suffix (e.g. "Resolute Clam #58a68a"),
/// the words part is rendered large with [baseStyle], while the hex suffix
/// is styled slightly smaller (subscript-like) with subtle opacity.
class FormattedDisplayName extends StatelessWidget {
  final String? displayName;
  final String username;
  final TextStyle baseStyle;
  final TextStyle? hexStyle;
  final TextOverflow overflow;
  final int maxLines;

  const FormattedDisplayName({
    super.key,
    required this.displayName,
    required this.username,
    required this.baseStyle,
    this.hexStyle,
    this.overflow = TextOverflow.ellipsis,
    this.maxLines = 1,
  });

  @override
  Widget build(BuildContext context) {
    final hasDisplayName = displayName != null && displayName!.trim().isNotEmpty;
    if (hasDisplayName) {
      return Text(
        displayName!,
        style: baseStyle,
        overflow: overflow,
        maxLines: maxLines,
      );
    }

    final hashIndex = username.indexOf('#');
    if (hashIndex != -1) {
      final wordsPart = username.substring(0, hashIndex);
      final hexPart = username.substring(hashIndex);

      final double fontSize = baseStyle.fontSize ?? 15.5;
      final Color baseColor = baseStyle.color ??
          (Theme.of(context).brightness == Brightness.dark
              ? Colors.white
              : const Color(0xFF17202A));

      final effectiveHexStyle = hexStyle ??
          baseStyle.copyWith(
            fontSize: fontSize * 0.76, // Slightly smaller subscript-like size
            fontWeight: FontWeight.w500,
            color: baseColor.withValues(alpha: 0.65),
          );

      return Text.rich(
        TextSpan(
          text: wordsPart,
          style: baseStyle,
          children: [
            TextSpan(
              text: hexPart,
              style: effectiveHexStyle,
            ),
          ],
        ),
        overflow: overflow,
        maxLines: maxLines,
      );
    }

    return Text(
      username,
      style: baseStyle,
      overflow: overflow,
      maxLines: maxLines,
    );
  }
}
