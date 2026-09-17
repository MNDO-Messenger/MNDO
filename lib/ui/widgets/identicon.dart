import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:crypto/crypto.dart';

class Identicon extends StatelessWidget {
  final String seed;
  final double size;

  const Identicon({super.key, required this.seed, this.size = 48.0});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Theme.of(context).colorScheme.surfaceVariant ?? Theme.of(context).cardTheme.color ?? Colors.grey.withOpacity(0.2),
      ),
      child: ClipOval(
        child: CustomPaint(
          painter: _IdenticonPainter(seed),
        ),
      ),
    );
  }
}

class _IdenticonPainter extends CustomPainter {
  final String seed;

  _IdenticonPainter(this.seed);

  @override
  void paint(Canvas canvas, Size size) {
    // Generate deterministic bytes from the seed
    final bytes = sha256.convert(utf8.encode(seed)).bytes;
    
    // Use the first byte to determine the Hue (0-360 degrees)
    final hue = (bytes[0] / 255.0) * 360.0;
    
    // Keep Saturation fixed at 70% and Lightness at 55% for optimal contrast
    final color = HSLColor.fromAHSL(1.0, hue, 0.70, 0.55).toColor();

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
      
    // 5x5 grid, but we give a 1-block padding around it, so total width = 7 blocks
    final blockSize = size.width / 7; 
    final padding = blockSize;
    
    // 3 columns to calculate (0, 1, 2). Col 3 and 4 are mirrors of 1 and 0.
    int byteIdx = 3;
    for (int col = 0; col < 3; col++) {
      for (int row = 0; row < 5; row++) {
        // Use even/odd of the byte to determine if the block is filled
        final draw = bytes[byteIdx % bytes.length] % 2 == 0;
        byteIdx++;
        
        if (draw) {
          // Draw left/center block
          canvas.drawRect(
            Rect.fromLTWH(padding + col * blockSize, padding + row * blockSize, blockSize, blockSize),
            paint,
          );
          
          // Draw right mirrored block
          if (col != 2) {
            final mirroredCol = 4 - col;
            canvas.drawRect(
              Rect.fromLTWH(padding + mirroredCol * blockSize, padding + row * blockSize, blockSize, blockSize),
              paint,
            );
          }
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return oldDelegate is _IdenticonPainter && oldDelegate.seed != seed;
  }
}
