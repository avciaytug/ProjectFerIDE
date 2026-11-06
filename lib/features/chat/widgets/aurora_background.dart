import 'package:flutter/material.dart';
import '../../../theme/ide_palette.dart';

class AuroraBackground extends StatelessWidget {
  final Widget child;
  const AuroraBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    if (Theme.of(context).brightness == Brightness.light) {
      return child;
    }
    return Stack(
      children: [
        // Arka planı RepaintBoundary ile izole ederek boşta %0 CPU kullanımını sağla
        RepaintBoundary(
          child: Stack(
            children: [
              Container(color: Theme.of(context).colorScheme.surface),
              Positioned(
                top: -80,
                left: -80,
                child: _buildBlob(IdePalette.auroraViolet.withValues(alpha: 0.18), 480),
              ),
              Positioned(
                bottom: -120,
                right: -80,
                child: _buildBlob(IdePalette.auroraIndigo.withValues(alpha: 0.15), 520),
              ),
              Positioned(
                top: MediaQuery.of(context).size.height / 3,
                left: MediaQuery.of(context).size.width / 3,
                child: _buildBlob(IdePalette.auroraBlue.withValues(alpha: 0.10), 600),
              ),
              // Izgara katmanı
              Positioned.fill(
                child: CustomPaint(
                  painter: _GridPainter(
                    Theme.of(context).brightness == Brightness.dark 
                        ? Colors.white.withValues(alpha: 0.01)
                        : Colors.black.withValues(alpha: 0.03)
                  ),
                ),
              ),
            ],
          ),
        ),
        child,
      ],
    );
  }

  Widget _buildBlob(Color color, double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [color, Colors.transparent],
        ),
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  final Color gridColor;
  _GridPainter(this.gridColor);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = gridColor
      ..strokeWidth = 1.0;
      
    const step = 40.0;
    for (double i = 0; i < size.width; i += step) {
      canvas.drawLine(Offset(i, 0), Offset(i, size.height), paint);
    }
    for (double i = 0; i < size.height; i += step) {
      canvas.drawLine(Offset(0, i), Offset(size.width, i), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
