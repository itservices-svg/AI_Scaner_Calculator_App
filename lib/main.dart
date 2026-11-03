import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

void main() => runApp(const HandWriteApp());

class HandWriteApp extends StatelessWidget {
  const HandWriteApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'HandWrite AI',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
        home: const CalculatorPage(),
      );
}

// ---------------------------------------------------------------- painting

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

// -------------------------------------------------------------- recognizer

class DigitRecognizer {
  late final Interpreter _interp;

  Future<void> load() async {
    _interp = await Interpreter.fromAsset('assets/digit_model.tflite');
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
      final output = [List<double>.filled(10, 0.0)];
      _interp.run(input, output);
      var best = 0;
      for (var i = 1; i < 10; i++) {
        if (output[0][i] > output[0][best]) best = i;
      }
      sb.write(best);
    }
    return sb.toString();
  }
}

// -------------------------------------------------------------- calculator

String evaluate(String expr) {
  final tokens =
      RegExp(r'\d+|[+\-×÷]').allMatches(expr).map((m) => m.group(0)!).toList();
  if (tokens.isEmpty) return '';
  final nums = <double>[];
  final ops = <String>[];
  for (var i = 0; i < tokens.length; i++) {
    if (i.isEven) {
      final n = double.tryParse(tokens[i]);
      if (n == null) return 'Error';
      nums.add(n);
    } else {
      if (!'+-×÷'.contains(tokens[i])) return 'Error';
      ops.add(tokens[i]);
    }
  }
  if (nums.length != ops.length + 1) return 'Error';

  final n2 = <double>[nums[0]];
  final o2 = <String>[];
  for (var i = 0; i < ops.length; i++) {
    if (ops[i] == '×') {
      n2[n2.length - 1] *= nums[i + 1];
    } else if (ops[i] == '÷') {
      if (nums[i + 1] == 0) return 'Error';
      n2[n2.length - 1] /= nums[i + 1];
    } else {
      o2.add(ops[i]);
      n2.add(nums[i + 1]);
    }
  }
  var r = n2[0];
  for (var i = 0; i < o2.length; i++) {
    r = o2[i] == '+' ? r + n2[i + 1] : r - n2[i + 1];
  }
  if (r == r.roundToDouble()) return r.toInt().toString();
  return r.toStringAsFixed(4).replaceFirst(RegExp(r'0+$'), '');
}

class CalculatorPage extends StatefulWidget {
  const CalculatorPage({super.key});
  @override
  State<CalculatorPage> createState() => _CalculatorPageState();
}

class _CalculatorPageState extends State<CalculatorPage> {
  final recognizer = DigitRecognizer();
  final List<List<Offset>> strokes = [];
  bool ready = false;
  String expr = '';
  String result = '';

  @override
  void initState() {
    super.initState();
    recognizer.load().then((_) {
      if (mounted) setState(() => ready = true);
    });
  }

  Future<void> _addNumber() async {
    if (!ready || strokes.isEmpty) return;
    final digits = await recognizer.recognize(strokes);
    setState(() {
      if (result.isNotEmpty) {
        expr = '';
        result = '';
      }
      expr += digits;
      strokes.clear();
    });
  }

  void _addOp(String op) {
    setState(() {
      if (result.isNotEmpty && result != 'Error') {
        expr = result;
        result = '';
      }
      if (expr.isEmpty) return;
      if ('+-×÷'.contains(expr[expr.length - 1])) {
        expr = expr.substring(0, expr.length - 1);
      }
      expr += op;
    });
  }

  void _equals() {
    if (expr.isEmpty) return;
    setState(() => result = evaluate(expr));
  }

  void _backspace() {
    if (expr.isEmpty) return;
    setState(() {
      expr = expr.substring(0, expr.length - 1);
      result = '';
    });
  }

  void _clearAll() => setState(() {
        expr = '';
        result = '';
        strokes.clear();
      });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('HandWrite AI')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(expr.isEmpty ? '0' : expr,
                        style: const TextStyle(fontSize: 28)),
                    Text(result.isEmpty ? ' ' : '= $result',
                        style: TextStyle(
                            fontSize: 36,
                            fontWeight: FontWeight.bold,
                            color: cs.primary)),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: GestureDetector(
                    onPanStart: (d) =>
                        setState(() => strokes.add([d.localPosition])),
                    onPanUpdate: (d) =>
                        setState(() => strokes.last.add(d.localPosition)),
                    child: SizedBox.expand(
                      child: CustomPaint(painter: StrokePainter(strokes)),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                ready
                    ? 'Number likho (multi-digit ho sakta hai), phir "Add" dabao'
                    : 'Model load ho raha hai...',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => setState(() => strokes.clear()),
                      child: const Text('Clear canvas'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      onPressed: ready ? _addNumber : null,
                      child: const Text('Add number'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  for (final op in ['+', '-', '×', '÷'])
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: FilledButton.tonal(
                          onPressed: () => _addOp(op),
                          child: Text(op, style: const TextStyle(fontSize: 22)),
                        ),
                      ),
                    ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: FilledButton(
                        onPressed: _equals,
                        child: const Text('=', style: TextStyle(fontSize: 22)),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: IconButton.filledTonal(
                        onPressed: _backspace,
                        onLongPress: _clearAll,
                        icon: const Icon(Icons.backspace_outlined),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
