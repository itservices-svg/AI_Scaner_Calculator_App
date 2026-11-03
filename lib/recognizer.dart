import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import 'stroke_painter.dart';

class DigitRecognizer {
  late final Interpreter _interp;

  Future<void> load() async {
    _interp = await Interpreter.fromAsset('assets/digit_model.tflite');
  }

  /// 28x28 (0..1, white digit on black) pixels ko classify karta hai.
  /// Returns (digit, confidence).
  (int, double) classify(Float32List px) {
    final input = [
      List.generate(
        28,
        (y) => List.generate(28, (x) => [px[y * 28 + x].toDouble()]),
      ),
    ];
    return _predict(input);
  }

  (int, double) _predict(List<List<List<List<double>>>> input) {
    final output = [List<double>.filled(10, 0.0)];
    _interp.run(input, output);
    var best = 0;
    for (var i = 1; i < 10; i++) {
      if (output[0][i] > output[0][best]) best = i;
    }
    return (best, output[0][best]);
  }

  /// Strokes ko left-to-right digits mein group karta hai (x-range overlap se).
  List<List<List<Offset>>> _group(List<List<Offset>> strokes) {
    double minX(List<Offset> s) => s.map((p) => p.dx).reduce(min);
    double maxX(List<Offset> s) => s.map((p) => p.dx).reduce(max);

    final items = strokes.where((s) => s.isNotEmpty).toList()
      ..sort((a, b) => minX(a).compareTo(minX(b)));

    final groups = <List<List<Offset>>>[];
    double curMax = -1e9;
    for (final s in items) {
      if (groups.isNotEmpty && minX(s) <= curMax + 6) {
        groups.last.add(s);
        curMax = max(curMax, maxX(s));
      } else {
        groups.add([s]);
        curMax = maxX(s);
      }
    }
    return groups;
  }

  /// Ek digit ke strokes ko 28x28 (MNIST style: 20x20 box, center mein) banata hai.
  Future<List<List<List<List<double>>>>> _render(List<List<Offset>> g) async {
    final pts = g.expand((s) => s).toList();
    final l = pts.map((p) => p.dx).reduce(min);
    final r = pts.map((p) => p.dx).reduce(max);
    final t = pts.map((p) => p.dy).reduce(min);
    final b = pts.map((p) => p.dy).reduce(max);
    final side = max(max(r - l, b - t), 60.0);
    final scale = 20 / side;

    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.drawRect(const Rect.fromLTWH(0, 0, 28, 28), Paint()..color = Colors.black);
    c.translate(14, 14);
    c.scale(scale);
    c.translate(-(l + r) / 2, -(t + b) / 2);
    StrokePainter.drawStrokes(c, g);

    final img = await rec.endRecording().toImage(28, 28);
    final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    final bytes = bd!.buffer.asUint8List();

    return [
      List.generate(
        28,
        (y) => List.generate(28, (x) => [bytes[(y * 28 + x) * 4] / 255.0]),
      ),
    ];
  }

  Future<String> recognize(List<List<Offset>> strokes) async {
    final sb = StringBuffer();
    for (final g in _group(strokes)) {
      final input = await _render(g);
      sb.write(_predict(input).$1);
    }
    return sb.toString();
  }
}
