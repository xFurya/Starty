// Значок приложения: классический в трёх цветах (основной — «Лёд») и с сегодняшним числом.
// Набор — assets/icon/variants.json (общий с tools/icons, откуда рисуются значки Android и iPhone).
//
// Где как ставится:
//  • Android — псевдонимы активности (AppIcons.kt); число значка «С сегодняшним числом» меняется в полночь;
//  • iPhone — альтернативные значки, только без числа: сменить число без вопроса системы нельзя;
//  • Windows и macOS — значок окна, панели задач и Дока, пока приложение открыто
//    (ярлык в «Пуске» и значок в Finder — классические); число меняется в полночь.
import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, Directory;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'platform.dart';

class IconVariant {
  final String id, group, name;
  final String? band;
  final Color? line;
  const IconVariant(this.id, this.group, this.name, this.band, this.line);
  bool get dated => group == 'date';
}

class AppIcons {
  static const _ch = MethodChannel('starty/icon');
  static List<IconVariant> _all = const [];
  static Timer? _midnight;

  /// Есть ли выбор значка на этой платформе (ICONS=true — показать окно на стенде в браузере).
  static bool get supported => const bool.fromEnvironment('ICONS') || (!kIsWeb && (isAndroid || isIos || isDesktop));

  static Future<List<IconVariant>> load() async {
    if (_all.isNotEmpty) return _all;
    final j = jsonDecode(await rootBundle.loadString('assets/icon/variants.json')) as Map<String, dynamic>;
    final lines = (j['lines'] as Map).map((k, v) => MapEntry('$k', _hex('$v')));
    _all = [
      for (final v in j['variants'] as List)
        IconVariant(v['id'], v['group'], v['name'], v['band'], v['line'] == null ? null : lines[v['line']]),
    ];
    return _all;
  }

  /// Варианты, которые здесь можно поставить.
  static Future<List<IconVariant>> available() async =>
      [for (final v in await load()) if (!(isIos && v.dated)) v];

  static Color _hex(String s) => Color(int.parse('FF${s.substring(1)}', radix: 16));

  static Future<String> current() async {
    try {
      if (isAndroid || isIos) return await _ch.invokeMethod<String>('get') ?? 'classic';
    } catch (_) {}
    final p = await SharedPreferences.getInstance();
    return p.getString('icon') ?? 'classic';
  }

  /// Поставить значок. false — система отказала.
  static Future<bool> set(String id) async {
    try {
      if (isAndroid || isIos) return await _ch.invokeMethod<bool>('set', id) ?? false;
      final p = await SharedPreferences.getInstance();
      await p.setString('icon', id);
      await applyDesktop();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Компьютер: значок окна и Дока по выбору; у значка с числом — перерисовать в полночь.
  static Future<void> applyDesktop() async {
    if (!isDesktop) return;
    _midnight?.cancel();
    final id = await current();
    final v = (await load()).where((x) => x.id == id).firstOrNull;
    if (v == null || id == 'classic') {
      if (id == 'classic') await _sendDesktop(null);
      return;
    }
    final now = DateTime.now();
    final png = await renderIcon(v, now.day, 256);
    await _sendDesktop(png);
    if (v.dated) {
      final next = DateTime(now.year, now.month, now.day + 1, 0, 0, 2);
      _midnight = Timer(next.difference(now), applyDesktop);
    }
  }

  static Future<void> _sendDesktop(Uint8List? png) async {
    try {
      if (isMac) {
        await _ch.invokeMethod('window', png);
      } else if (isWindows) {
        if (png == null) {
          await _ch.invokeMethod('window', '');
          return;
        }
        final dir = await Directory.systemTemp.createTemp('starty_icon');
        final f = File('${dir.path}\\icon.ico');
        await f.writeAsBytes(_ico(png));
        await _ch.invokeMethod('window', f.path);
      }
    } catch (_) {}
  }

  /// ICO с одной картинкой PNG внутри (Windows Vista и новее читают такие сами).
  static Uint8List _ico(Uint8List png) {
    final b = BytesBuilder();
    final h = ByteData(6 + 16);
    h.setUint16(0, 0, Endian.little);
    h.setUint16(2, 1, Endian.little);
    h.setUint16(4, 1, Endian.little);
    h.setUint8(6, 0); // 256
    h.setUint8(7, 0);
    h.setUint8(8, 0);
    h.setUint8(9, 0);
    h.setUint16(10, 1, Endian.little);
    h.setUint16(12, 32, Endian.little);
    h.setUint32(14, png.length, Endian.little);
    h.setUint32(18, 22, Endian.little);
    b.add(h.buffer.asUint8List());
    b.add(png);
    return b.toBytes();
  }

  // ---------------------------------------------------------------- рисование

  static final Map<String, ui.Image> _images = {};

  static Future<ui.Image> _image(String name) async {
    final have = _images[name];
    if (have != null) return have;
    final data = await rootBundle.load('assets/icon/layers/$name.png');
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    return _images[name] = (await codec.getNextFrame()).image;
  }

  /// Значок картинкой PNG [px]×[px] — как его рисует tools/icons/render.js.
  static Future<Uint8List> renderIcon(IconVariant v, int day, int px) async {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    await paint(c, Size.square(px.toDouble()), v, day);
    final img = await rec.endRecording().toImage(px, px);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  }

  static Future<void> paint(Canvas c, Size s, IconVariant v, int day) async {
    final dst = Offset.zero & s;
    void draw(ui.Image im) => c.drawImageRect(
      im,
      Rect.fromLTWH(0, 0, im.width.toDouble(), im.height.toDouble()),
      dst,
      Paint()..filterQuality = FilterQuality.high,
    );
    draw(await _image('bg'));
    draw(await _image('skater'));
    if (v.dated) paintNumber(c, s, day, v.line ?? Colors.white);
    if (v.band != null) draw(await _image('band_${v.band}'));
  }

  /// Число дня: полупрозрачная заливка и цветной контур со свечением (размеры — из render.js).
  static void paintNumber(Canvas c, Size s, int day, Color line) {
    final k = s.width / 1024;
    final t = '$day';
    final size = (t.length > 1 ? 600 : 640) * k;
    final spacing = (t.length > 1 ? -36 : 0) * k;
    TextPainter tp(Paint fg) => TextPainter(
      text: TextSpan(
        text: t,
        style: TextStyle(fontFamily: 'Manrope', fontWeight: FontWeight.w700, fontSize: size, letterSpacing: spacing, foreground: fg, height: 1),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    void at(TextPainter p) {
      // базовая линия на 790 из 1024, по центру
      final base = p.computeDistanceToActualBaseline(TextBaseline.alphabetic);
      p.paint(c, Offset((s.width - p.width) / 2, 790 * k - base));
    }
    final fill = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Colors.white.withValues(alpha: .42), Colors.white.withValues(alpha: .16)],
      ).createShader(Rect.fromLTWH(0, 790 * k - size * .75, s.width, size * .75));
    at(tp(fill));
    at(tp(Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 30 * k
      ..strokeJoin = StrokeJoin.round
      ..color = line.withValues(alpha: .45)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 9 * k)));
    at(tp(Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 15 * k
      ..strokeJoin = StrokeJoin.round
      ..color = line));
  }
}

/// Предпросмотр значка: скруглённый квадрат, число — сегодняшнее.
class IconPreview extends StatefulWidget {
  final IconVariant variant;
  final double size;
  const IconPreview({super.key, required this.variant, this.size = 64});
  @override
  State<IconPreview> createState() => _IconPreviewState();
}

class _IconPreviewState extends State<IconPreview> {
  Uint8List? png;

  @override
  void initState() {
    super.initState();
    _draw();
  }

  @override
  void didUpdateWidget(IconPreview old) {
    super.didUpdateWidget(old);
    if (old.variant.id != widget.variant.id) _draw();
  }

  Future<void> _draw() async {
    final v = widget.variant;
    final bytes = await AppIcons.renderIcon(v, DateTime.now().day, 256);
    if (mounted) setState(() => png = bytes);
  }

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(widget.size * .23),
    child: SizedBox.square(
      dimension: widget.size,
      child: png == null ? const ColoredBox(color: Color(0xFF123F72)) : Image.memory(png!, fit: BoxFit.cover, gaplessPlayback: true),
    ),
  );
}
