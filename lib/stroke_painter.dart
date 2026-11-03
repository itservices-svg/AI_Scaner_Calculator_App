import 'package:flutter/material.dart';

class StrokePainter extends CustomPainter {
  final List<List<Offset>> strokes;
  StrokePainter(this.strokes);

  static const double strokeWidth = 24;

  static void drawStrokes(Canvas canvas, List<List<Offset>> strokes) {
    final line = Paint()
      ..color = Colors.white
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;
    final dot = Paint()
      ..color = Colors.white
      ..isAntiAlias = true;
    for (final s in strokes) {
      if (s.isEmpty) continue;
      if (s.length == 1) {
        canvas.drawCircle(s.first, strokeWidth / 2, dot);
      } else {
        final path = Path()..moveTo(s.first.dx, s.first.dy);
        for (final p in s.skip(1)) {
          path.lineTo(p.dx, p.dy);
        }
        canvas.drawPath(path, line);
      }
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);
    drawStrokes(canvas, strokes);
  }

  @override
  bool shouldRepaint(covariant StrokePainter old) => true;
}
