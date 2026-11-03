import 'package:flutter/material.dart';

import 'recognizer.dart';
import 'stroke_painter.dart';

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
  final DigitRecognizer recognizer;
  const CalculatorPage({super.key, required this.recognizer});
  @override
  State<CalculatorPage> createState() => _CalculatorPageState();
}

class _CalculatorPageState extends State<CalculatorPage> {
  DigitRecognizer get recognizer => widget.recognizer;
  final List<List<Offset>> strokes = [];
  final bool ready = true;
  String expr = '';
  String result = '';

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
