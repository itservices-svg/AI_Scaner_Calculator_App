import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import 'recognizer.dart';
import 'scan_processor.dart';

enum ScanOp { sum, sub, mul, div, avg, lowest, highest }

const _opLabels = {
  ScanOp.sum: 'Jama (+)',
  ScanOp.sub: 'Minus (−)',
  ScanOp.mul: 'Zarb (×)',
  ScanOp.div: 'Taqseem (÷)',
  ScanOp.avg: 'Average',
  ScanOp.lowest: 'Sab se chota',
  ScanOp.highest: 'Sab se bara',
};

const _opSymbols = {
  ScanOp.sum: ' + ',
  ScanOp.sub: ' − ',
  ScanOp.mul: ' × ',
  ScanOp.div: ' ÷ ',
};

class _Entry {
  final TextEditingController ctrl;
  final bool low; // model ko yaqeen kam tha
  _Entry(String text, this.low) : ctrl = TextEditingController(text: text);
}

class ScanPage extends StatefulWidget {
  final DigitRecognizer recognizer;
  const ScanPage({super.key, required this.recognizer});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final _picker = ImagePicker();
  bool busy = false;
  String? error;
  ScanResult? scan;
  List<bool> glyphLow = [];
  List<_Entry> entries = [];
  ScanOp op = ScanOp.sum;

  @override
  void dispose() {
    for (final e in entries) {
      e.ctrl.dispose();
    }
    super.dispose();
  }

  Future<void> _pick(ImageSource source) async {
    try {
      final file = await _picker.pickImage(
        source: source,
        maxWidth: 2000,
        imageQuality: 92,
      );
      if (file == null) return;
      setState(() {
        busy = true;
        error = null;
      });
      final bytes = await file.readAsBytes();
      final res = await compute(processScan, bytes);

      final lows = <bool>[];
      final found = <_Entry>[];
      var curId = -1;
      StringBuffer? sb;
      var curLow = false;
      for (final g in res.glyphs) {
        final (digit, conf) = widget.recognizer.classify(g.pixels);
        final isLow = conf < 0.8;
        lows.add(isLow);
        if (g.numberId != curId) {
          final done = sb;
          if (done != null) found.add(_Entry(done.toString(), curLow));
          curId = g.numberId;
          sb = StringBuffer();
          curLow = false;
        }
        sb!.write(digit);
        if (isLow) curLow = true;
      }
      final last = sb;
      if (last != null) found.add(_Entry(last.toString(), curLow));

      if (!mounted) return;
      for (final e in entries) {
        e.ctrl.dispose();
      }
      setState(() {
        scan = res;
        glyphLow = lows;
        entries = found;
        busy = false;
        if (found.isEmpty) {
          error = 'Koi number nahi mila. Saaf kaagaz, achhi roshni mein, '
              'bara likh kar dobara try karo.';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        busy = false;
        error = 'Scan nahi ho saka: $e';
      });
    }
  }

  List<double> get _values => entries
      .map((e) => double.tryParse(e.ctrl.text.trim().replaceAll(',', '')))
      .whereType<double>()
      .toList();

  String _fmt(double r) {
    if (r == r.roundToDouble() && r.abs() < 1e15) return r.toInt().toString();
    return r
        .toStringAsFixed(4)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }

  String _result() {
    final v = _values;
    if (v.isEmpty) return '-';
    double r;
    switch (op) {
      case ScanOp.sum:
        r = v.fold(0.0, (a, b) => a + b);
      case ScanOp.sub:
        r = v.skip(1).fold(v.first, (a, b) => a - b);
      case ScanOp.mul:
        r = v.fold(1.0, (a, b) => a * b);
      case ScanOp.div:
        r = v.first;
        for (final b in v.skip(1)) {
          if (b == 0) return 'Error (0 se taqseem)';
          r /= b;
        }
      case ScanOp.avg:
        r = v.fold(0.0, (a, b) => a + b) / v.length;
      case ScanOp.lowest:
        r = v.reduce((a, b) => a < b ? a : b);
      case ScanOp.highest:
        r = v.reduce((a, b) => a > b ? a : b);
    }
    return _fmt(r);
  }

  String _expression() {
    final sym = _opSymbols[op];
    if (sym == null) return '';
    return _values.map(_fmt).join(sym);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = scan;
    return Scaffold(
      appBar: AppBar(title: const Text('Scan Calculator')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: busy ? null : () => _pick(ImageSource.camera),
                    icon: const Icon(Icons.photo_camera),
                    label: const Text('Camera'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: busy ? null : () => _pick(ImageSource.gallery),
                    icon: const Icon(Icons.photo_library_outlined),
                    label: const Text('Gallery'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Saaf kaagaz par, achhi roshni mein, bara likho. Numbers ke '
              'darmiyan gap ya nayi line rakho. Photo seedhi lo.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (busy) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
            ],
            if (error != null) ...[
              const SizedBox(height: 12),
              Text(error!, style: TextStyle(color: cs.error)),
            ],
            if (s != null) ...[
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: AspectRatio(
                  aspectRatio: s.width / s.height,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.memory(s.previewJpg,
                          fit: BoxFit.fill, gaplessPlayback: true),
                      CustomPaint(painter: _BoxPainter(s, glyphLow)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Hara = pakka, narangi = shak (check kar lo).',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (s != null || entries.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('Mile hue numbers (galat ho to theek karo)',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var i = 0; i < entries.length; i++) _entryField(i, cs),
                  ActionChip(
                    avatar: const Icon(Icons.add, size: 18),
                    label: const Text('Number'),
                    onPressed: () =>
                        setState(() => entries.add(_Entry('', false))),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final o in ScanOp.values)
                    ChoiceChip(
                      label: Text(_opLabels[o]!),
                      selected: op == o,
                      onSelected: (_) => setState(() => op = o),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (_expression().isNotEmpty)
                      Text(_expression(),
                          textAlign: TextAlign.right,
                          style: const TextStyle(fontSize: 16)),
                    Text(
                      '= ${_result()}',
                      style: TextStyle(
                        fontSize: 34,
                        fontWeight: FontWeight.bold,
                        color: cs.primary,
                      ),
                    ),
                    Text('${_values.length} numbers',
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _entryField(int i, ColorScheme cs) {
    final e = entries[i];
    final border = OutlineInputBorder(
      borderSide: BorderSide(color: e.low ? Colors.orange : cs.outline),
    );
    return SizedBox(
      key: ObjectKey(e),
      width: 120,
      child: TextField(
        controller: e.ctrl,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          isDense: true,
          border: border,
          enabledBorder: border,
          suffixIconConstraints:
              const BoxConstraints(minWidth: 30, minHeight: 30),
          suffixIcon: InkWell(
            onTap: () => setState(() {
              entries.removeAt(i).ctrl.dispose();
            }),
            child: const Icon(Icons.close, size: 16),
          ),
        ),
      ),
    );
  }
}

class _BoxPainter extends CustomPainter {
  final ScanResult scan;
  final List<bool> low;
  _BoxPainter(this.scan, this.low);

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / scan.width;
    final sy = size.height / scan.height;
    for (var i = 0; i < scan.glyphs.length; i++) {
      final g = scan.glyphs[i];
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = (i < low.length && low[i]) ? Colors.orange : Colors.greenAccent;
      canvas.drawRect(
        Rect.fromLTRB(g.left * sx, g.top * sy, (g.right + 1) * sx,
            (g.bottom + 1) * sy),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BoxPainter old) =>
      old.scan != scan || old.low != low;
}
