import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Kaagaz ki photo se nikla hua ek digit (MNIST style 28x28) aur uski jagah.
class ScanGlyph {
  final Float32List pixels; // 28*28, 0..1, white digit on black
  final int line; // kaun si line (upar se neeche)
  final int numberId; // kaun sa number (reading order)
  final int left, top, right, bottom; // preview image ke coordinates
  ScanGlyph(this.pixels, this.line, this.numberId, this.left, this.top,
      this.right, this.bottom);
}

class ScanResult {
  final Uint8List previewJpg;
  final int width, height;
  final List<ScanGlyph> glyphs;
  ScanResult(this.previewJpg, this.width, this.height, this.glyphs);
}

class _Comp {
  int l, t, r, b;
  int area = 0;
  final Set<int> ids;
  _Comp(int id, this.l, this.t, this.r, this.b) : ids = {id};

  int get w => r - l + 1;
  int get h => b - t + 1;
  double get cy => (t + b) / 2;

  void absorb(_Comp o) {
    l = min(l, o.l);
    t = min(t, o.t);
    r = max(r, o.r);
    b = max(b, o.b);
    area += o.area;
    ids.addAll(o.ids);
  }
}

/// Top-level function taake `compute()` se background isolate mein chal sake.
ScanResult processScan(Uint8List bytes) {
  var im = img.decodeImage(bytes);
  if (im == null) throw Exception('Image parh nahi sakay');
  im = img.bakeOrientation(im);

  const maxSide = 1280;
  if (im.width > maxSide || im.height > maxSide) {
    im = im.width >= im.height
        ? img.copyResize(im, width: maxSide)
        : img.copyResize(im, height: maxSide);
  }
  final w = im.width;
  final h = im.height;
  final preview = Uint8List.fromList(img.encodeJpg(im, quality: 80));

  // 1) Grayscale
  final gray = Uint8List(w * h);
  for (final p in im) {
    final v = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
    gray[p.y * w + p.x] = v < 0 ? 0 : (v > 255 ? 255 : v.round());
  }

  // 2) Adaptive threshold (local mean, integral image) -> ink mask
  final iw = w + 1;
  final integral = Int32List((w + 1) * (h + 1));
  for (var y = 0; y < h; y++) {
    var rowSum = 0;
    for (var x = 0; x < w; x++) {
      rowSum += gray[y * w + x];
      integral[(y + 1) * iw + (x + 1)] = integral[y * iw + (x + 1)] + rowSum;
    }
  }
  final rad = max(15, min(w, h) ~/ 25);
  final ink = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    final y0 = max(0, y - rad);
    final y1 = min(h - 1, y + rad);
    for (var x = 0; x < w; x++) {
      final x0 = max(0, x - rad);
      final x1 = min(w - 1, x + rad);
      final sum = integral[(y1 + 1) * iw + (x1 + 1)] -
          integral[y0 * iw + (x1 + 1)] -
          integral[(y1 + 1) * iw + x0] +
          integral[y0 * iw + x0];
      final cnt = (x1 - x0 + 1) * (y1 - y0 + 1);
      if ((gray[y * w + x] + 15) * cnt < sum) ink[y * w + x] = 1;
    }
  }

  // 3) Connected components (8-neighbour)
  final labels = Int32List(w * h);
  final stack = Int32List(w * h);
  final comps = <_Comp>[];
  var nextId = 0;
  for (var i = 0; i < w * h; i++) {
    if (ink[i] == 0 || labels[i] != 0) continue;
    nextId++;
    var sp = 0;
    stack[sp++] = i;
    labels[i] = nextId;
    var l = w, t = h, r = 0, b = 0, area = 0;
    while (sp > 0) {
      final cur = stack[--sp];
      final cx = cur % w;
      final cy = cur ~/ w;
      area++;
      if (cx < l) l = cx;
      if (cx > r) r = cx;
      if (cy < t) t = cy;
      if (cy > b) b = cy;
      for (var dy = -1; dy <= 1; dy++) {
        final ny = cy + dy;
        if (ny < 0 || ny >= h) continue;
        for (var dx = -1; dx <= 1; dx++) {
          final nx = cx + dx;
          if (nx < 0 || nx >= w) continue;
          final ni = ny * w + nx;
          if (ink[ni] == 1 && labels[ni] == 0) {
            labels[ni] = nextId;
            stack[sp++] = ni;
          }
        }
      }
    }
    comps.add(_Comp(nextId, l, t, r, b)..area = area);
  }

  // 4) Noise / lines / borders filter
  final minArea = max(25, (w * h * 0.00003).round());
  var cand = comps
      .where((c) => c.area >= minArea && c.w <= w * 0.5 && c.h <= h * 0.5)
      .toList();
  if (cand.isEmpty) return ScanResult(preview, w, h, []);
  final hs = cand.map((c) => c.h).toList()..sort();
  final medH = hs[hs.length ~/ 2].toDouble();
  cand = cand.where((c) => c.h >= medH * 0.35).toList();
  if (cand.isEmpty) return ScanResult(preview, w, h, []);

  // 5) Lines (upar se neeche)
  cand.sort((a, b) => a.cy.compareTo(b.cy));
  final lines = <List<_Comp>>[];
  final lineCy = <double>[];
  for (final c in cand) {
    if (lines.isNotEmpty && (c.cy - lineCy.last).abs() <= medH * 0.6) {
      lines.last.add(c);
      lineCy[lineCy.length - 1] =
          lines.last.map((e) => e.cy).reduce((a, b) => a + b) /
              lines.last.length;
    } else {
      lines.add([c]);
      lineCy.add(c.cy);
    }
  }

  // 6) Har line mein: toote hue strokes jodo (4, 5, 7...), phir numbers banao
  final glyphs = <ScanGlyph>[];
  var numberId = -1;
  for (var li = 0; li < lines.length; li++) {
    final row = lines[li]..sort((a, b) => a.l.compareTo(b.l));
    final merged = <_Comp>[];
    for (final c in row) {
      if (merged.isNotEmpty) {
        final m = merged.last;
        final overlap = min(m.r, c.r) - max(m.l, c.l) + 1;
        if (overlap > 0 && overlap >= min(m.w, c.w) * 0.4) {
          m.absorb(c);
          continue;
        }
      }
      merged.add(c);
    }
    _Comp? prev;
    for (final g in merged) {
      if (prev == null || g.l - prev.r > medH * 0.7) numberId++;
      glyphs.add(_renderGlyph(g, labels, w, li, numberId));
      prev = g;
    }
  }
  return ScanResult(preview, w, h, glyphs);
}

/// Ek digit ko MNIST style 28x28 mein badalta hai:
/// stroke moti karo, 20x20 mein fit karo, center of mass se center karo.
ScanGlyph _renderGlyph(_Comp g, Int32List labels, int w, int line, int numberId) {
  final cw = g.w;
  final ch = g.h;
  final mask = Uint8List(cw * ch);
  var area = 0;
  for (var y = 0; y < ch; y++) {
    for (var x = 0; x < cw; x++) {
      final lab = labels[(g.t + y) * w + (g.l + x)];
      if (lab != 0 && g.ids.contains(lab)) {
        mask[y * cw + x] = 1;
        area++;
      }
    }
  }

  // stroke width ka andaza = 2*area/perimeter
  var perim = 0;
  for (var y = 0; y < ch; y++) {
    for (var x = 0; x < cw; x++) {
      if (mask[y * cw + x] == 0) continue;
      final edge = x == 0 ||
          y == 0 ||
          x == cw - 1 ||
          y == ch - 1 ||
          mask[y * cw + x - 1] == 0 ||
          mask[y * cw + x + 1] == 0 ||
          mask[(y - 1) * cw + x] == 0 ||
          mask[(y + 1) * cw + x] == 0;
      if (edge) perim++;
    }
  }
  final strokeW = perim == 0 ? 1.0 : 2.0 * area / perim;
  final target = 0.10 * max(cw, ch);
  var r = ((target - strokeW) / 2).round();
  if (r < 0) r = 0;
  if (r > 12) r = 12;

  // padded + dilate (square, separable)
  final pw = cw + 2 * r;
  final ph = ch + 2 * r;
  var cur = Uint8List(pw * ph);
  for (var y = 0; y < ch; y++) {
    for (var x = 0; x < cw; x++) {
      cur[(y + r) * pw + (x + r)] = mask[y * cw + x];
    }
  }
  if (r > 0) {
    final tmp = Uint8List(pw * ph);
    for (var y = 0; y < ph; y++) {
      for (var x = 0; x < pw; x++) {
        if (cur[y * pw + x] == 1) {
          for (var k = max(0, x - r); k <= min(pw - 1, x + r); k++) {
            tmp[y * pw + k] = 1;
          }
        }
      }
    }
    final out = Uint8List(pw * ph);
    for (var y = 0; y < ph; y++) {
      for (var x = 0; x < pw; x++) {
        if (tmp[y * pw + x] == 1) {
          for (var k = max(0, y - r); k <= min(ph - 1, y + r); k++) {
            out[k * pw + x] = 1;
          }
        }
      }
    }
    cur = out;
  }

  // 20 px ki longest side tak box-average downscale
  final scale = 20.0 / max(pw, ph);
  final tw = max(1, (pw * scale).round());
  final th = max(1, (ph * scale).round());
  final patch = List<double>.filled(tw * th, 0.0);
  for (var ty = 0; ty < th; ty++) {
    final y0 = (ty * ph / th).floor();
    final y1 = min(ph, ((ty + 1) * ph / th).ceil());
    for (var tx = 0; tx < tw; tx++) {
      final x0 = (tx * pw / tw).floor();
      final x1 = min(pw, ((tx + 1) * pw / tw).ceil());
      var sum = 0;
      var count = 0;
      for (var yy = y0; yy < y1; yy++) {
        for (var xx = x0; xx < x1; xx++) {
          sum += cur[yy * pw + xx];
          count++;
        }
      }
      patch[ty * tw + tx] = count == 0 ? 0.0 : sum / count;
    }
  }

  // center of mass ko 28x28 ke center par lao
  var mass = 0.0, mx = 0.0, my = 0.0, peak = 0.0;
  for (var ty = 0; ty < th; ty++) {
    for (var tx = 0; tx < tw; tx++) {
      final v = patch[ty * tw + tx];
      mass += v;
      mx += v * tx;
      my += v * ty;
      if (v > peak) peak = v;
    }
  }
  if (mass > 0) {
    mx /= mass;
    my /= mass;
  } else {
    mx = tw / 2;
    my = th / 2;
  }
  final offX = (13.5 - mx).round();
  final offY = (13.5 - my).round();
  final gain = peak > 0 ? 1.0 / peak : 1.0;

  final px = Float32List(28 * 28);
  for (var ty = 0; ty < th; ty++) {
    for (var tx = 0; tx < tw; tx++) {
      final ox = tx + offX;
      final oy = ty + offY;
      if (ox < 0 || ox >= 28 || oy < 0 || oy >= 28) continue;
      final v = patch[ty * tw + tx] * gain;
      px[oy * 28 + ox] = v > 1.0 ? 1.0 : v;
    }
  }
  return ScanGlyph(px, line, numberId, g.l, g.t, g.r, g.b);
}
