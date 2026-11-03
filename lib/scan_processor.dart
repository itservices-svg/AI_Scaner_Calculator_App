import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Ek line mein do digits ke darmiyan gap (digit ki unchai ka multiple) is se
/// kam ho to wo ek hi number hai ("1  20" -> 120). Is se bara gap = alag number.
const double _numberGap = 1.5;

/// Kaagaz ki photo se nikla hua ek digit (MNIST style 28x28) aur uski jagah.
class ScanGlyph {
  final Float32List pixels; // 28*28, 0..1, white digit on black
  final int line; // kaun si line (upar se neeche)
  final int numberId; // kaun sa number (reading order)
  final int left, top, right, bottom; // preview image ke coordinates
  final bool rejected; // digit jaisi shakal nahi (naam, line, dash...)
  ScanGlyph(this.pixels, this.line, this.numberId, this.left, this.top,
      this.right, this.bottom,
      [this.rejected = false]);
}

/// Crop chunne ke liye photo ka resized version.
class PreparedImage {
  final Uint8List jpg;
  final int width, height;
  PreparedImage(this.jpg, this.width, this.height);
}

/// Scan ki request: photo + crop rect (0..1 fractions; poora page = 0,0,1,1).
class ScanRequest {
  final Uint8List bytes;
  final double l, t, r, b;
  ScanRequest(this.bytes, this.l, this.t, this.r, this.b);
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

class _CC {
  final Int32List labels;
  final List<_Comp> comps;
  _CC(this.labels, this.comps);
}

class _Band {
  final List<ScanGlyph> glyphs;
  final int lines;
  final int lastNumberId;
  _Band(this.glyphs, this.lines, this.lastNumberId);
}

class _Plan {
  final double digitH; // andaza: ek digit ki unchai (work image ke pixels)
  final List<int> cuts; // band kaatne ki y positions (sirf blank gaps par)
  _Plan(this.digitH, this.cuts);
}

int _ci(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

img.Image _decode(Uint8List bytes) {
  final d = img.decodeImage(bytes);
  if (d == null) throw Exception('Image parh nahi sakay');
  return img.bakeOrientation(d);
}

/// Longest side ko `long` pixels par lata hai (chhota karte waqt average).
img.Image _fit(img.Image im, int long) {
  final cur = max(im.width, im.height);
  if (cur == long) return im;
  final interp =
      long < cur ? img.Interpolation.average : img.Interpolation.linear;
  return im.width >= im.height
      ? img.copyResize(im, width: long, interpolation: interp)
      : img.copyResize(im, height: long, interpolation: interp);
}

Uint8List _gray(img.Image im) {
  final w = im.width;
  final g = Uint8List(w * im.height);
  for (final p in im) {
    final v = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
    g[p.y * w + p.x] = v < 0 ? 0 : (v > 255 ? 255 : v.round());
  }
  return g;
}

/// Adaptive threshold (local mean, integral image): ink = 1.
Uint8List _inkMask(Uint8List gray, int w, int h, int rad, int delta) {
  final iw = w + 1;
  final integral = Int32List((w + 1) * (h + 1));
  for (var y = 0; y < h; y++) {
    var rowSum = 0;
    for (var x = 0; x < w; x++) {
      rowSum += gray[y * w + x];
      integral[(y + 1) * iw + (x + 1)] = integral[y * iw + (x + 1)] + rowSum;
    }
  }
  final ink = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    final ya = max(0, y - rad);
    final yb = min(h - 1, y + rad);
    for (var x = 0; x < w; x++) {
      final xa = max(0, x - rad);
      final xb = min(w - 1, x + rad);
      final sum = integral[(yb + 1) * iw + (xb + 1)] -
          integral[ya * iw + (xb + 1)] -
          integral[(yb + 1) * iw + xa] +
          integral[ya * iw + xa];
      final cnt = (xb - xa + 1) * (yb - ya + 1);
      if ((gray[y * w + x] + delta) * cnt < sum) ink[y * w + x] = 1;
    }
  }
  return ink;
}

/// Connected components (8-neighbour).
_CC _components(Uint8List ink, int w, int h) {
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
  return _CC(labels, comps);
}

/// Top-level functions taake `compute()` se background isolate mein chal sakein.
PreparedImage prepareScan(Uint8List bytes) {
  var im = _decode(bytes);
  if (max(im.width, im.height) > 1280) im = _fit(im, 1280);
  return PreparedImage(
      Uint8List.fromList(img.encodeJpg(im, quality: 80)), im.width, im.height);
}

ScanResult processScan(ScanRequest req) {
  var im = _decode(req.bytes);

  // crop (fractions poori photo ke)
  final fw = im.width;
  final fh = im.height;
  final cx0 = _ci((req.l * fw).round(), 0, fw - 2);
  final cy0 = _ci((req.t * fh).round(), 0, fh - 2);
  final cx1 = _ci((req.r * fw).round(), cx0 + 2, fw);
  final cy1 = _ci((req.b * fh).round(), cy0 + 2, fh);
  if (cx1 - cx0 < fw || cy1 - cy0 < fh) {
    im = img.copyCrop(im, x: cx0, y: cy0, width: cx1 - cx0, height: cy1 - cy0);
  }

  // working size: bohat bari ho to 3200, bohat chhoti ho to 800
  const maxWork = 3200;
  final longSide = max(im.width, im.height);
  var work = im;
  if (longSide > maxWork) {
    work = _fit(im, maxWork);
  } else if (longSide < 640) {
    work = _fit(im, 800);
  }

  List<ScanGlyph> single() => _scanBand(work, 0, 0, 0, -1).glyphs;

  var glyphs = <ScanGlyph>[];
  if (max(work.width, work.height) <= 1500) {
    glyphs = single();
  } else {
    var plan = _plan(work);
    // digits bare hon to itni resolution ki zaroorat nahi
    if (plan.digitH > 110) {
      final f = 80.0 / plan.digitH;
      final nl = max(1280, (max(work.width, work.height) * f).round());
      work = _fit(work, nl);
      plan = _plan(work);
    }
    if (max(work.width, work.height) <= 1500) {
      glyphs = single();
    } else {
      // Tiling: bands ke darmiyan cuts sirf blank gaps par hain, is liye
      // koi number/digit kabhi nahi tootta.
      final rad = _ci((plan.digitH * 0.75).round(), 12, 80);
      final minArea = max(12, (plan.digitH * plan.digitH * 0.02).round());
      final bounds = [0, ...plan.cuts, work.height];
      var lineBase = 0;
      var numBase = -1;
      for (var bi = 0; bi + 1 < bounds.length; bi++) {
        final y0 = bounds[bi];
        final y1 = bounds[bi + 1];
        if (y1 - y0 < 8) continue;
        final bandIm = bounds.length == 2
            ? work
            : img.copyCrop(work, x: 0, y: y0, width: work.width, height: y1 - y0);
        final out = _scanBand(bandIm, rad, minArea, lineBase, numBase);
        for (final g in out.glyphs) {
          glyphs.add(ScanGlyph(g.pixels, g.line, g.numberId, g.left,
              g.top + y0, g.right, g.bottom + y0, g.rejected));
        }
        lineBase += out.lines;
        numBase = out.lastNumberId;
      }
    }
  }

  final preview = Uint8List.fromList(img.encodeJpg(work, quality: 72));
  return ScanResult(preview, work.width, work.height, glyphs);
}

/// Coarse (1/4) nazar se: digit ki unchai ka andaza + band cuts (blank rows).
_Plan _plan(img.Image work) {
  const q = 4;
  final cw = max(8, work.width ~/ q);
  final ch = max(8, work.height ~/ q);
  final small = img.copyResize(work,
      width: cw, height: ch, interpolation: img.Interpolation.average);
  final gray = _gray(small);
  final ink = _inkMask(gray, cw, ch, max(8, min(cw, ch) ~/ 25), 12);

  // digit unchai ka andaza: components ki unchai (60th percentile)
  final cc = _components(ink, cw, ch);
  final hs = cc.comps
      .where((c) => c.area >= 6 && c.h >= 4)
      .map((c) => c.h)
      .toList()
    ..sort();
  final digitH = hs.isEmpty ? 40.0 : hs[(hs.length * 0.6).floor()] * q * 1.0;

  // row projection
  final rowCnt = List<int>.filled(ch, 0);
  for (var y = 0; y < ch; y++) {
    var c = 0;
    for (var x = 0; x < cw; x++) {
      c += ink[y * cw + x];
    }
    rowCnt[y] = c;
  }
  final blankMax = max(1, (cw * 0.004).round());
  bool blank(int y) => rowCnt[y] <= blankMax;

  // band ki unchai: ~3.2 million pixels per band
  final targetPx = max(600, 3200000 ~/ work.width);
  final target = max(8, targetPx ~/ q);
  final cuts = <int>[];
  var last = 0;
  while (ch - last > target * 1.5) {
    final nominal = last + target;
    var found = -1;
    for (var d = 0; d < ch; d++) {
      final f = nominal + d;
      final bk = nominal - d;
      if (f < ch - 1 && blank(f)) {
        found = f;
        break;
      }
      if (d <= target ~/ 2 && bk > last + target ~/ 2 && blank(bk)) {
        found = bk;
        break;
      }
      if (f >= ch - 1 && bk <= last) break;
    }
    if (found < 0) break;
    var a = found;
    var z = found;
    while (a > last + 1 && blank(a - 1)) {
      a--;
    }
    while (z < ch - 2 && blank(z + 1)) {
      z++;
    }
    final mid = (a + z) ~/ 2;
    cuts.add(mid * q + q ~/ 2);
    last = mid;
  }
  return _Plan(digitH, cuts);
}

/// Ek band (ya poori chhoti image) scan karta hai.
/// rad = threshold window (0 = auto), minAreaIn = chhote noise ki had (0 = auto)
_Band _scanBand(
    img.Image im, int radIn, int minAreaIn, int lineBase, int numBase) {
  final w = im.width;
  final h = im.height;
  final gray = _gray(im);
  final rad = radIn > 0 ? radIn : max(15, min(w, h) ~/ 25);
  final ink = _inkMask(gray, w, h, rad, 15);
  final cc = _components(ink, w, h);
  final labels = cc.labels;

  // Noise / lines / borders filter
  final minArea =
      minAreaIn > 0 ? minAreaIn : max(25, (w * h * 0.00003).round());
  var cand = cc.comps
      .where((c) => c.area >= minArea && c.w <= w * 0.5 && c.h <= h * 0.5)
      .toList();
  if (cand.isEmpty) return _Band([], 0, numBase);
  final hs = cand.map((c) => c.h).toList()..sort();
  final medH = hs[hs.length ~/ 2].toDouble();
  cand = cand.where((c) => c.h >= medH * 0.35).toList();
  if (cand.isEmpty) return _Band([], 0, numBase);

  // Lines (upar se neeche)
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

  // Har line mein toote hue strokes jodo (4, 5, 7...)
  final rows = <List<_Comp>>[];
  for (final line in lines) {
    final row = line..sort((a, b) => a.l.compareTo(b.l));
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
    rows.add(merged);
  }
  final gh = rows.expand((r) => r).map((g) => g.h).toList()..sort();
  final medG = gh[gh.length ~/ 2].toDouble();

  // Numbers banao. Jo digit jaisa na lage (chhota/ lamba/ dash/ naam) reject.
  final glyphs = <ScanGlyph>[];
  var numberId = numBase;
  for (var li = 0; li < rows.length; li++) {
    _Comp? prev;
    for (final g in rows[li]) {
      final bad = g.w / g.h > 1.3 || g.h < medG * 0.5 || g.h > medG * 2.2;
      if (bad) {
        glyphs.add(ScanGlyph(
            Float32List(784), lineBase + li, -1, g.l, g.t, g.r, g.b, true));
        continue;
      }
      if (prev == null || g.l - prev.r > medG * _numberGap) numberId++;
      glyphs.add(_renderGlyph(g, labels, w, lineBase + li, numberId));
      prev = g;
    }
  }
  return _Band(glyphs, rows.length, numberId);
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
