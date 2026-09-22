import 'package:flutter/material.dart';

/// WhatsApp-style text editing controller providing:
/// 1. Automatic list continuation on newline (ordered lists, bullet lists, blockquotes)
/// 2. Instant conversion of `- ` or `* ` into `• ` (bullet list)
/// 3. Live inline syntax styling in the TextField (*bold*, _italic_, ~strike~, `code`)
class WhatsAppTextEditingController extends TextEditingController {
  WhatsAppTextEditingController({super.text});

  @override
  set value(TextEditingValue newValue) {
    final oldText = text;
    final newText = newValue.text;
    final sel = newValue.selection;

    // 1. Instant conversion of '-' or '*' + space at line start to bullet '• '
    if (newText.length == oldText.length + 1 &&
        sel.isCollapsed &&
        sel.baseOffset > 1 &&
        newText[sel.baseOffset - 1] == ' ') {
      final cursor = sel.baseOffset;
      final textBeforeSpace = newText.substring(0, cursor - 1);
      final lastNewlineIdx = textBeforeSpace.lastIndexOf('\n');
      final currentLine = lastNewlineIdx == -1
          ? textBeforeSpace
          : textBeforeSpace.substring(lastNewlineIdx + 1);

      if (currentLine.trim() == '-' || currentLine.trim() == '*') {
        final indent = RegExp(r'^\s*').firstMatch(currentLine)?.group(0) ?? '';
        final lineStart = lastNewlineIdx == -1 ? 0 : lastNewlineIdx + 1;
        final replacement = '$indent• ';
        final updatedText = newText.substring(0, lineStart) + replacement + newText.substring(cursor);
        super.value = TextEditingValue(
          text: updatedText,
          selection: TextSelection.collapsed(offset: lineStart + replacement.length),
        );
        return;
      }
    }

    // 2. Intelligent List Continuation on newline '\n'
    if (newText.length > oldText.length &&
        sel.isCollapsed &&
        sel.baseOffset > 0 &&
        newText[sel.baseOffset - 1] == '\n') {
      final cursor = sel.baseOffset;
      final textBeforeNewline = newText.substring(0, cursor - 1);
      final lastNewlineIdx = textBeforeNewline.lastIndexOf('\n');
      final prevLine = lastNewlineIdx == -1
          ? textBeforeNewline
          : textBeforeNewline.substring(lastNewlineIdx + 1);

      final modified = _handleNewlineContinuation(
        prevLine: prevLine,
        newText: newText,
        cursor: cursor,
        lastNewlineIdx: lastNewlineIdx,
      );

      if (modified != null) {
        super.value = modified;
        return;
      }
    }

    super.value = newValue;
  }

  TextEditingValue? _handleNewlineContinuation({
    required String prevLine,
    required String newText,
    required int cursor,
    required int lastNewlineIdx,
  }) {
    // 1. Ordered list continuation: e.g. "1. " or "  1. "
    final numMatch = RegExp(r'^(\s*)(\d+)\.\s*(.*)$').firstMatch(prevLine);
    if (numMatch != null) {
      final indent = numMatch.group(1) ?? '';
      final num = int.tryParse(numMatch.group(2) ?? '') ?? 1;
      final content = numMatch.group(3) ?? '';

      if (content.trim().isEmpty) {
        // Empty list item -> Terminate the list by removing the number from prevLine
        final lineStart = lastNewlineIdx == -1 ? 0 : lastNewlineIdx + 1;
        final beforeLine = newText.substring(0, lineStart);
        final afterNewline = newText.substring(cursor);
        final updatedText = beforeLine + afterNewline;
        return TextEditingValue(
          text: updatedText,
          selection: TextSelection.collapsed(offset: lineStart),
        );
      } else {
        // Continue list with next number
        final nextPrefix = '$indent${num + 1}. ';
        final beforeCursor = newText.substring(0, cursor);
        final afterCursor = newText.substring(cursor);
        final updatedText = beforeCursor + nextPrefix + afterCursor;
        return TextEditingValue(
          text: updatedText,
          selection: TextSelection.collapsed(offset: cursor + nextPrefix.length),
        );
      }
    }

    // 2. Unordered bullet list continuation: e.g. "- ", "* ", "• "
    final bulletMatch = RegExp(r'^(\s*)([-*•])\s*(.*)$').firstMatch(prevLine);
    if (bulletMatch != null) {
      final indent = bulletMatch.group(1) ?? '';
      final bullet = bulletMatch.group(2) ?? '•';
      final content = bulletMatch.group(3) ?? '';

      if (content.trim().isEmpty) {
        // Empty bullet item -> Terminate the list by removing the bullet from prevLine
        final lineStart = lastNewlineIdx == -1 ? 0 : lastNewlineIdx + 1;
        final beforeLine = newText.substring(0, lineStart);
        final afterNewline = newText.substring(cursor);
        final updatedText = beforeLine + afterNewline;
        return TextEditingValue(
          text: updatedText,
          selection: TextSelection.collapsed(offset: lineStart),
        );
      } else {
        // Continue bullet list
        final nextPrefix = '$indent$bullet ';
        final beforeCursor = newText.substring(0, cursor);
        final afterCursor = newText.substring(cursor);
        final updatedText = beforeCursor + nextPrefix + afterCursor;
        return TextEditingValue(
          text: updatedText,
          selection: TextSelection.collapsed(offset: cursor + nextPrefix.length),
        );
      }
    }

    // 3. Blockquote continuation: e.g. "> "
    final quoteMatch = RegExp(r'^(\s*)(>)\s*(.*)$').firstMatch(prevLine);
    if (quoteMatch != null) {
      final indent = quoteMatch.group(1) ?? '';
      final content = quoteMatch.group(3) ?? '';

      if (content.trim().isEmpty) {
        // Empty quote -> Terminate quote
        final lineStart = lastNewlineIdx == -1 ? 0 : lastNewlineIdx + 1;
        final beforeLine = newText.substring(0, lineStart);
        final afterNewline = newText.substring(cursor);
        final updatedText = beforeLine + afterNewline;
        return TextEditingValue(
          text: updatedText,
          selection: TextSelection.collapsed(offset: lineStart),
        );
      } else {
        // Continue quote
        final nextPrefix = '$indent> ';
        final beforeCursor = newText.substring(0, cursor);
        final afterCursor = newText.substring(cursor);
        final updatedText = beforeCursor + nextPrefix + afterCursor;
        return TextEditingValue(
          text: updatedText,
          selection: TextSelection.collapsed(offset: cursor + nextPrefix.length),
        );
      }
    }

    return null;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final baseStyle = style ?? const TextStyle();
    if (text.isEmpty) {
      return TextSpan(text: '', style: baseStyle);
    }
    return WhatsAppFormatter.parseEditorSpans(text, baseStyle);
  }
}

/// Formatter utilities for WhatsApp markdown parsing & rendering
class WhatsAppFormatter {
  static final RegExp _inlineRegex = RegExp(
    r'(\*[^\s*](?:[^*]*?[^\s*])?\*)|' +
    r'(_[^\s_](?:[^_]*?[^\s_])?_)|' +
    r'(~[^\s~](?:[^~]*?[^\s~])?~)|' +
    r'(`[^\s`](?:[^`]*?[^\s`])?`)',
    multiLine: true,
  );

  /// Builds TextSpans for the text editor keeping delimiters visible with subtle styling
  static TextSpan parseEditorSpans(String text, TextStyle baseStyle) {
    final delimiterStyle = baseStyle.copyWith(
      color: (baseStyle.color ?? Colors.black).withValues(alpha: 0.42),
      fontWeight: FontWeight.normal,
      fontStyle: FontStyle.normal,
      decoration: TextDecoration.none,
    );

    final spans = <InlineSpan>[];
    int lastEnd = 0;

    for (final match in _inlineRegex.allMatches(text)) {
      if (match.start > lastEnd) {
        spans.add(TextSpan(text: text.substring(lastEnd, match.start), style: baseStyle));
      }

      final matchedStr = match.group(0)!;
      final delimiter = matchedStr[0];
      final content = matchedStr.substring(1, matchedStr.length - 1);

      TextStyle activeStyle = baseStyle;
      if (delimiter == '*') {
        activeStyle = baseStyle.copyWith(fontWeight: FontWeight.bold);
      } else if (delimiter == '_') {
        activeStyle = baseStyle.copyWith(fontStyle: FontStyle.italic);
      } else if (delimiter == '~') {
        activeStyle = baseStyle.copyWith(decoration: TextDecoration.lineThrough);
      } else if (delimiter == '`') {
        activeStyle = baseStyle.copyWith(
          fontFamily: 'monospace',
          backgroundColor: (baseStyle.color ?? Colors.grey).withValues(alpha: 0.12),
        );
      }

      spans.add(TextSpan(text: delimiter, style: delimiterStyle));
      spans.add(TextSpan(text: content, style: activeStyle));
      spans.add(TextSpan(text: delimiter, style: delimiterStyle));

      lastEnd = match.end;
    }

    if (lastEnd < text.length) {
      spans.add(TextSpan(text: text.substring(lastEnd), style: baseStyle));
    }

    return TextSpan(children: spans, style: baseStyle);
  }

  /// Parses inline markdown for display in chat bubbles (delimiters stripped)
  static List<InlineSpan> parseBubbleInline(
    String text,
    TextStyle currentStyle, {
    int depth = 0,
    required Color codeBg,
  }) {
    if (depth > 3 || text.isEmpty) {
      return [TextSpan(text: text, style: currentStyle)];
    }

    final spans = <InlineSpan>[];
    int lastEnd = 0;

    for (final match in _inlineRegex.allMatches(text)) {
      if (match.start > lastEnd) {
        spans.add(TextSpan(
          text: text.substring(lastEnd, match.start),
          style: currentStyle,
        ));
      }

      final matchedStr = match.group(0)!;
      final delimiter = matchedStr[0];
      final inner = matchedStr.substring(1, matchedStr.length - 1);

      TextStyle newStyle = currentStyle;
      if (delimiter == '*') {
        newStyle = currentStyle.copyWith(fontWeight: FontWeight.bold);
      } else if (delimiter == '_') {
        newStyle = currentStyle.copyWith(fontStyle: FontStyle.italic);
      } else if (delimiter == '~') {
        newStyle = currentStyle.copyWith(decoration: TextDecoration.lineThrough);
      } else if (delimiter == '`') {
        newStyle = currentStyle.copyWith(
          fontFamily: 'monospace',
          fontSize: (currentStyle.fontSize ?? 15) * 0.92,
          backgroundColor: codeBg,
        );
        spans.add(TextSpan(text: inner, style: newStyle));
        lastEnd = match.end;
        continue;
      }

      // Recursively parse inner for nested formats (e.g. *_bold italic_*)
      spans.addAll(parseBubbleInline(
        inner,
        newStyle,
        depth: depth + 1,
        codeBg: codeBg,
      ));

      lastEnd = match.end;
    }

    if (lastEnd < text.length) {
      spans.add(TextSpan(
        text: text.substring(lastEnd),
        style: currentStyle,
      ));
    }

    return spans;
  }
}

/// Rich WhatsApp-style formatted message widget for chat bubbles
class WhatsAppFormattedText extends StatelessWidget {
  final String text;
  final TextStyle baseStyle;
  final bool isMine;
  final bool isDark;

  const WhatsAppFormattedText({
    super.key,
    required this.text,
    required this.baseStyle,
    required this.isMine,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    // 1. Check for multiline code blocks (```code```)
    if (text.contains('```')) {
      return _buildCodeBlockDocument();
    }

    // 2. Check for multiline blockquotes or list items
    final lines = text.split('\n');
    final hasBlockElements = lines.any((line) {
      final trimmed = line.trimLeft();
      return trimmed.startsWith('>') ||
          RegExp(r'^[-*•]\s+').hasMatch(trimmed) ||
          RegExp(r'^\d+\.\s+').hasMatch(trimmed);
    });

    if (hasBlockElements) {
      return _buildBlockElements(lines);
    }

    // 3. Simple inline paragraph
    final codeBg = isDark
        ? const Color(0xFF141416).withValues(alpha: 0.8)
        : (isMine ? Colors.white.withValues(alpha: 0.4) : const Color(0xFFE2E8F0));

    return Text.rich(
      TextSpan(
        children: WhatsAppFormatter.parseBubbleInline(
          text,
          baseStyle,
          codeBg: codeBg,
        ),
      ),
      textAlign: TextAlign.start,
    );
  }

  Widget _buildCodeBlockDocument() {
    final parts = text.split('```');
    final children = <Widget>[];
    final codeBg = isDark
        ? const Color(0xFF141416)
        : (isMine ? const Color(0xFFC7E6FA) : const Color(0xFFF1F5F9));
    final codeBorder = isDark
        ? const Color(0xFF2A2A30)
        : (isMine ? const Color(0xFFB0DCF7) : const Color(0xFFE2E8F0));

    for (int i = 0; i < parts.length; i++) {
      final part = parts[i];
      if (part.isEmpty) continue;

      if (i % 2 == 1) {
        // Code Block
        final codeText = part.startsWith('\n') ? part.substring(1) : part;
        final cleanCode = codeText.endsWith('\n') ? codeText.substring(0, codeText.length - 1) : codeText;

        children.add(
          Container(
            width: double.infinity,
            margin: const EdgeInsets.symmetric(vertical: 4.0),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: codeBg,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: codeBorder, width: 0.8),
            ),
            child: SelectableText(
              cleanCode,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                height: 1.35,
                color: isDark ? const Color(0xFFE4E4E7) : const Color(0xFF1E293B),
              ),
            ),
          ),
        );
      } else {
        // Normal text before/after code block
        final lines = part.split('\n');
        children.add(_buildBlockElements(lines));
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  Widget _buildBlockElements(List<String> lines) {
    final widgets = <Widget>[];
    final codeBg = isDark
        ? const Color(0xFF141416).withValues(alpha: 0.8)
        : (isMine ? Colors.white.withValues(alpha: 0.4) : const Color(0xFFE2E8F0));
    final quoteBarColor = isMine
        ? (isDark ? const Color(0xFF818CF8) : const Color(0xFF2563EB))
        : (isDark ? const Color(0xFF6366F1) : const Color(0xFF4F46E5));

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      final trimmed = line.trimLeft();

      // Blockquote (> Quote)
      if (trimmed.startsWith('>')) {
        final quoteContent = trimmed.substring(1).trimLeft();
        widgets.add(
          Container(
            margin: const EdgeInsets.symmetric(vertical: 2.0),
            padding: const EdgeInsets.fromLTRB(10, 3, 6, 3),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(color: quoteBarColor, width: 3.0),
              ),
              color: quoteBarColor.withValues(alpha: isDark ? 0.12 : 0.07),
              borderRadius: const BorderRadius.only(
                topRight: Radius.circular(4),
                bottomRight: Radius.circular(4),
              ),
            ),
            child: Text.rich(
              TextSpan(
                children: WhatsAppFormatter.parseBubbleInline(
                  quoteContent,
                  baseStyle.copyWith(
                    fontStyle: FontStyle.italic,
                    color: baseStyle.color?.withValues(alpha: 0.9),
                  ),
                  codeBg: codeBg,
                ),
              ),
            ),
          ),
        );
        continue;
      }

      // Bullet List (- Item, * Item, • Item)
      final bulletMatch = RegExp(r'^([-*•])\s+(.*)$').firstMatch(trimmed);
      if (bulletMatch != null) {
        final itemText = bulletMatch.group(2) ?? '';
        widgets.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1.5),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 7.0, top: 2.0),
                  child: Text(
                    '•',
                    style: baseStyle.copyWith(
                      fontWeight: FontWeight.bold,
                      fontSize: (baseStyle.fontSize ?? 15) * 1.05,
                    ),
                  ),
                ),
                Flexible(
                  child: Text.rich(
                    TextSpan(
                      children: WhatsAppFormatter.parseBubbleInline(
                        itemText,
                        baseStyle,
                        codeBg: codeBg,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
        continue;
      }

      // Numbered List (1. Item)
      final numMatch = RegExp(r'^(\d+\.)\s+(.*)$').firstMatch(trimmed);
      if (numMatch != null) {
        final numPrefix = numMatch.group(1) ?? '';
        final itemText = numMatch.group(2) ?? '';
        widgets.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1.5),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 6.0),
                  child: Text(
                    numPrefix,
                    style: baseStyle.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Flexible(
                  child: Text.rich(
                    TextSpan(
                      children: WhatsAppFormatter.parseBubbleInline(
                        itemText,
                        baseStyle,
                        codeBg: codeBg,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
        continue;
      }

      // Standard Line
      if (line.isNotEmpty || i < lines.length - 1) {
        widgets.add(
          Text.rich(
            TextSpan(
              children: WhatsAppFormatter.parseBubbleInline(
                line,
                baseStyle,
                codeBg: codeBg,
              ),
            ),
            textAlign: TextAlign.start,
          ),
        );
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: widgets,
    );
  }
}
