// Оформление «Лёд»: шрифты, слова, плашки, фото-шапка, аватары, медали, кнопки, нижняя панель.
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

import 'data.dart';
import 'main.dart';

/// Открытая вкладка: 0 — лента, 1 — месяц, 2 — настройки. Лист старта переключает
/// её сам, когда ведёт в настройки.
final homeTab = ValueNotifier<int>(0);
const tabSettings = 2;

// ------------------------------------------------------------------ шрифты

const serif = 'Cormorant';
const tnum = [FontFeature.tabularFigures()];

/// Заголовок экрана и крупные слова — антиква.
TextStyle display(Palette p, double size, {bool italic = false, Color? color, FontWeight? weight}) => TextStyle(
  fontFamily: serif,
  fontSize: size,
  fontWeight: weight ?? FontWeight.w600,
  fontStyle: italic ? FontStyle.italic : FontStyle.normal,
  height: 1.05,
  letterSpacing: -.2,
  color: color ?? p.ink,
);

/// Время: цифры одинаковой ширины.
TextStyle clock(Color color, double size, {FontWeight weight = FontWeight.w300}) =>
    TextStyle(fontSize: size, fontWeight: weight, height: 1.0, letterSpacing: -.6, color: color, fontFeatures: tnum);

// ------------------------------------------------------------------ слова

String cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// 1 старт, 2 старта, 5 стартов.
String plural(int n, String one, String few, String many) {
  final a = n.abs() % 100, b = a % 10;
  if (a >= 11 && a <= 14) return many;
  if (b == 1) return one;
  if (b >= 2 && b <= 4) return few;
  return many;
}

const kindNames = {'women': 'Женщины', 'men': 'Мужчины', 'pairs': 'Пары', 'dance': 'Танцы'};
const levelNames = {'senior': 'Взрослые', 'junior': 'Юниоры'};

const segNames = {'КП': 'короткая программа', 'ПП': 'произвольная программа', 'РТ': 'ритм-танец', 'ПТ': 'произвольный танец'};

/// «юниорские танцы ПТ» → («Юниорские танцы», «ПТ»).
(String, String) splitSegment(String segment) {
  final w = segment.trim().split(RegExp(r'\s+'));
  if (w.length > 1 && segNames.containsKey(w.last)) {
    return (cap(w.sublist(0, w.length - 1).join(' ')), w.last);
  }
  return (cap(segment), '');
}

String _title(String w) => w.isEmpty ? w : w[0] + w.substring(1).toLowerCase();
bool _capsWord(String w) => w.length > 1 && w == w.toUpperCase() && RegExp(r'[A-ZА-ЯЁ]').hasMatch(w);

/// «Kaori SAKAMOTO» → «Kaori Sakamoto»; русские имена без изменений.
String displayName(String name) =>
    name.split(' / ').map((n) => n.trim().split(RegExp(r'\s+')).map((w) => _capsWord(w) ? _title(w) : w).join(' ')).join(' / ');

/// Только фамилии: «Бойкова / Козловский», «Sakamoto».
String surname(String name) => name
    .split(' / ')
    .map((n) {
      final w = n.trim().split(RegExp(r'\s+'));
      final caps = w.where(_capsWord).toList();
      if (caps.isNotEmpty) return caps.map(_title).join(' ');
      return w.last;
    })
    .join(' / ');

String initials(String name) {
  final w = displayName(name).split(RegExp(r'\s+')).where((x) => x.isNotEmpty).toList();
  if (w.isEmpty) return '';
  if (w.length == 1) return w.first[0].toUpperCase();
  return (w.first[0] + w.last[0]).toUpperCase();
}

/// Пары — фамилиями, одиночники — «А. Заикина».
String placingName(Placing x) {
  if (x.name.contains(' / ')) return surname(x.name);
  final full = displayName(x.name).split(RegExp(r'\s+'));
  final last = surname(x.name);
  final first = full.firstWhere((w) => w != last, orElse: () => '');
  return first.isEmpty ? last : '${first[0]}. $last';
}

/// Код страны на экране: нейтральный статус — «AIN».
String nationCode(String n) => n.startsWith('AIN') ? 'AIN' : n;

/// «через 1 ч 50 мин»; меньше минуты — «через минуту».
String countdown(Duration d) {
  final m = (d.inSeconds / 60).ceil();
  if (m <= 1) return 'через минуту';
  final h = m ~/ 60, r = m % 60;
  if (h == 0) return 'через $r мин';
  return r == 0 ? 'через $h ч' : 'через $h ч $r мин';
}

/// Когда начало: сегодня — отсчёт, завтра — «завтра в 17:30», дальше — дата.
String whenLabel(Start s, DateTime t) {
  if (s.day == dayKey(t)) return countdown(s.t0.difference(t));
  if (s.day == dayKey(t.add(const Duration(days: 1)))) return 'завтра в ${hm(s.t0)}';
  final d = msk(s.t0);
  return '${d.day} ${months[d.month - 1]}';
}

/// «9 октября, 15:00» по Москве.
String dateTime(DateTime t) {
  final m = msk(t);
  return '${m.day} ${months[m.month - 1]}, ${hm(t)}';
}

// ------------------------------------------------------------------ плашки

/// Белая «ледяная» плашка: тонкая окантовка вместо тени.
class Plate extends StatelessWidget {
  final Widget child;
  final EdgeInsets margin;
  final EdgeInsets padding;
  const Plate({
    super.key,
    required this.child,
    this.margin = const EdgeInsets.symmetric(horizontal: 16),
    this.padding = EdgeInsets.zero,
  });
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      margin: margin,
      padding: padding,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: p.plateLine, width: 1),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: p.isDark ? [const Color(0xFF0F2134), p.plate] : [p.plate, const Color(0xFFFAFCFE)],
        ),
      ),
      child: child,
    );
  }
}

/// Тонкая линия между строками внутри плашки.
class Hairline extends StatelessWidget {
  final double indent;
  const Hairline({super.key, this.indent = 16});
  @override
  Widget build(BuildContext context) => Container(
    height: 1,
    margin: EdgeInsets.only(left: indent),
    color: Palette.of(context).line,
  );
}

/// Подпись раздела: мелкие прописные.
class Eyebrow extends StatelessWidget {
  final String text;
  final Color? color;
  final EdgeInsets padding;
  final Widget? trailing;
  const Eyebrow(this.text, {super.key, this.color, this.padding = EdgeInsets.zero, this.trailing});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final label = Text(
      text.toUpperCase(),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, letterSpacing: 1.3, color: color ?? p.ink3),
    );
    return Padding(
      padding: padding,
      child: trailing == null
          ? label
          : Row(
              children: [
                Expanded(child: label),
                trailing!,
              ],
            ),
    );
  }
}

// ------------------------------------------------------------------ шапка с фотографией льда

/// Шапка экрана: фото катка (светлое / ночное), фигуристка из иконки, заголовок антиквой.
/// Высота — не меньше [height]: крупный шрифт шапку растягивает, а не обрезает.
class IceHero extends StatelessWidget {
  final String eyebrow;
  final String title;
  final double titleSize;
  final List<Widget> actions;
  final double height;
  final bool figure;
  final int sparkles;
  const IceHero({
    super.key,
    required this.eyebrow,
    required this.title,
    this.titleSize = 44,
    this.actions = const [],
    this.height = 100,
    this.figure = false,
    this.sparkles = 0,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final top = MediaQuery.paddingOf(context).top;
    return Stack(
      children: [
        Positioned.fill(
          child: IceBackdrop(fadeTo: p.bg, sparkles: figure ? -1 : sparkles),
        ),
        if (figure)
          Positioned(
            right: 64,
            top: top + 4,
            bottom: 0,
            child: Image.asset(
              'assets/images/skater.png',
              fit: BoxFit.contain,
              alignment: Alignment.bottomRight,
              color: p.isDark ? Colors.white.withValues(alpha: .13) : Palette.iceBlue.withValues(alpha: .16),
              colorBlendMode: BlendMode.modulate,
            ),
          ),
        ConstrainedBox(
          constraints: BoxConstraints(minHeight: top + height, minWidth: double.infinity),
          child: Align(
            alignment: Alignment.bottomLeft,
            child: Padding(
              // кнопки справа вверху; подпись сезона — слева на их уровне, название — ниже кнопок
              padding: EdgeInsets.fromLTRB(20, top + (actions.isEmpty ? 16 : 26), 20, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Eyebrow(eyebrow, color: p.isDark ? p.ink2 : p.accent),
                  const SizedBox(height: 4),
                  // название целиком в одну строку: на узком экране — чуть мельче
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(title, maxLines: 1, style: display(p, titleSize)),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (actions.isNotEmpty)
          Positioned(
            top: top + 6,
            right: 10,
            child: Row(mainAxisSize: MainAxisSize.min, children: actions),
          ),
      ],
    );
  }
}

/// Фото льда, растворяющееся в фоне, с сиянием и искрами.
class IceBackdrop extends StatelessWidget {
  final Color fadeTo;
  final double fadeStart;
  final int sparkles;
  const IceBackdrop({super.key, required this.fadeTo, this.fadeStart = .35, this.sparkles = 0});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.asset(
          p.isDark ? 'assets/images/ice-dark.jpg' : 'assets/images/ice-light.jpg',
          fit: BoxFit.cover,
          alignment: const Alignment(0, -.4),
          filterQuality: FilterQuality.medium,
        ),
        // сияние льда, как в иконке
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(.55, -.35),
              radius: 1.0,
              colors: p.isDark
                  ? [Palette.iceBlue.withValues(alpha: .30), Palette.deepBlue.withValues(alpha: .55)]
                  : [Colors.white.withValues(alpha: .30), Colors.white.withValues(alpha: 0)],
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: [0, fadeStart, 1],
              colors: [
                fadeTo.withValues(alpha: p.isDark ? .25 : .0),
                fadeTo.withValues(alpha: p.isDark ? .35 : .15),
                fadeTo,
              ],
            ),
          ),
        ),
        if (sparkles >= 0)
          CustomPaint(
            painter: SparklePainter(p.isDark ? Colors.white : Palette.iceBlue, p.isDark ? .85 : .45, variant: sparkles),
          ),
      ],
    );
  }
}

/// Четырёхлучевые искры, как на иконке.
class SparklePainter extends CustomPainter {
  final Color color;
  final double opacity;
  final int variant;
  SparklePainter(this.color, this.opacity, {this.variant = 0});

  static const _layouts = [
    [(.80, .30, 11.0), (.90, .48, 6.0), (.70, .20, 4.5)],
    [(.86, .22, 9.0), (.74, .40, 4.5), (.95, .55, 3.5)],
    [(.78, .18, 7.0), (.90, .34, 10.0), (.66, .30, 3.5)],
    [(.74, .62, 10.0), (.86, .80, 5.5), (.63, .82, 4.0)],
  ];

  static void star(Canvas c, Offset o, double r, Paint paint) {
    final k = r * .16;
    final path = Path()
      ..moveTo(o.dx, o.dy - r)
      ..quadraticBezierTo(o.dx + k, o.dy - k, o.dx + r, o.dy)
      ..quadraticBezierTo(o.dx + k, o.dy + k, o.dx, o.dy + r)
      ..quadraticBezierTo(o.dx - k, o.dy + k, o.dx - r, o.dy)
      ..quadraticBezierTo(o.dx - k, o.dy - k, o.dx, o.dy - r)
      ..close();
    c.drawPath(path, paint);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final glow = Paint()
      ..color = color.withValues(alpha: opacity * .35)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    final fill = Paint()..color = color.withValues(alpha: opacity);
    final w = size.width, h = size.height;
    for (final (x, y, r) in _layouts[variant % _layouts.length]) {
      final o = Offset(w * x, h * y);
      canvas.drawCircle(o, r * .8, glow);
      star(canvas, o, r, fill);
    }
  }

  @override
  bool shouldRepaint(SparklePainter old) => old.color != color || old.opacity != opacity || old.variant != variant;
}

// ------------------------------------------------------------------ листы

/// Ручка листа: закреплена поверх содержимого, не уезжает при прокрутке.
class SheetHandle extends StatelessWidget {
  const SheetHandle({super.key});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return IgnorePointer(
      child: Center(
        child: Container(
          margin: const EdgeInsets.only(top: 9),
          width: 44,
          height: 5,
          decoration: BoxDecoration(
            color: p.isDark ? p.ink2.withValues(alpha: .75) : p.ink2.withValues(alpha: .55),
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: p.sheet.withValues(alpha: .6), width: .5),
          ),
        ),
      ),
    );
  }
}

/// Прокрутка листа с закреплённой ручкой: при прокрутке под ручкой — дымка цвета листа,
/// текст уходит под неё, а не под саму ручку.
class SheetScroll extends StatefulWidget {
  final Widget child;
  const SheetScroll({super.key, required this.child});
  @override
  State<SheetScroll> createState() => _SheetScrollState();
}

class _SheetScrollState extends State<SheetScroll> {
  bool scrolled = false;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Stack(
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: (n) {
            final s = n.metrics.pixels > 2;
            if (s != scrolled) setState(() => scrolled = s);
            return false;
          },
          child: SingleChildScrollView(child: widget.child),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: IgnorePointer(
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 150),
              opacity: scrolled ? 1 : 0,
              child: Container(
                height: 30,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: const [.6, 1],
                    colors: [p.sheet, p.sheet.withValues(alpha: 0)],
                  ),
                ),
              ),
            ),
          ),
        ),
        const Positioned(top: 0, left: 0, right: 0, child: SheetHandle()),
      ],
    );
  }
}

/// Кнопка листа 52 px: залитая (акцент) или с окантовкой. Без onTap — неактивна.
class SheetButton extends StatelessWidget {
  final bool filled;
  final bool neutral;
  final IconData? icon;
  final String label;
  final VoidCallback? onTap;

  /// По ширине надписи, а не на всю доступную ширину.
  final bool compact;
  const SheetButton({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.filled = false,
    this.neutral = false,
    this.compact = false,
  });
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final off = onTap == null;
    final fg = off ? p.ink3 : (filled ? p.onAccent : (neutral ? p.ink : p.accent));
    final text = Text(
      label,
      maxLines: 1,
      softWrap: false,
      style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, color: fg),
    );
    return Semantics(
      button: true,
      enabled: !off,
      child: Material(
        color: Colors.transparent,
        child: Ink(
          height: 52,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: filled && !off
                ? LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: p.isDark ? [p.accent, const Color(0xFF5E9FDC)] : const [Palette.iceBlue, Color(0xFF15457C)],
                  )
                : null,
            color: filled && !off ? null : (off ? p.line.withValues(alpha: .5) : p.plate),
            border: filled && !off
                ? null
                : Border.all(color: off ? p.line : (neutral ? p.plateLine : p.accent.withValues(alpha: .55)), width: 1.2),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onTap,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: compact ? 20 : 14),
              child: Row(
                mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (icon != null) ...[Icon(icon, size: 19, color: fg), const SizedBox(width: 8)],
                  if (compact)
                    text
                  else
                    Flexible(
                      child: FittedBox(fit: BoxFit.scaleDown, child: text),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ кнопки и выбор

/// Круглая кнопка 44×44 с тонкой окантовкой — для шапки.
class RoundButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final String tooltip;
  final int badge;
  const RoundButton({super.key, required this.icon, required this.onTap, required this.tooltip, this.badge = 0});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 48,
        height: 48,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Center(
              child: Material(
                color: p.plate.withValues(alpha: p.isDark ? .7 : .9),
                shape: CircleBorder(side: BorderSide(color: p.plateLine)),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: onTap,
                  child: SizedBox(width: 44, height: 44, child: Icon(icon, size: 21, color: p.ink)),
                ),
              ),
            ),
            if (badge > 0)
              Positioned(
                right: 0,
                top: 0,
                child: Container(
                  constraints: const BoxConstraints(minWidth: 18),
                  height: 18,
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: p.accent,
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(color: p.bg, width: 1.5),
                  ),
                  child: Text(
                    '$badge',
                    style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: p.onAccent, height: 1),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Перечёркнутый колокольчик: о будущем старте уведомления не будет.
class MutedBell extends StatelessWidget {
  final double size;
  const MutedBell({super.key, this.size = 15});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Semantics(
      label: 'Без уведомления',
      child: Icon(
        CupertinoIcons.bell_slash,
        size: size,
        color: p.ink3.withValues(alpha: p.isDark ? .9 : .85),
      ),
    );
  }
}

/// Ширина строки текста при текущем масштабе шрифта.
double textWidth(BuildContext context, String text, TextStyle style) {
  final tp = TextPainter(
    text: TextSpan(text: text, style: DefaultTextStyle.of(context).style.merge(style)),
    textDirection: TextDirection.ltr,
    maxLines: 1,
    textScaler: MediaQuery.textScalerOf(context),
  )..layout();
  return tp.width;
}

/// Плитка выбора: цветная точка (необязательно), подпись, галочка. Равные плитки сеткой.
class ChoiceTile extends StatelessWidget {
  final String label;
  final bool on;
  final Color? color;
  final VoidCallback? onTap;

  /// Узкая плитка: поля и значки меньше, подпись того же размера.
  final bool dense;
  const ChoiceTile({super.key, required this.label, required this.on, required this.onTap, this.color, this.dense = false});

  static const fontSize = 14.5;
  static TextStyle styleOf(bool on, Color ink) =>
      TextStyle(fontSize: fontSize, height: 1.2, fontWeight: on ? FontWeight.w700 : FontWeight.w500, color: ink);

  /// Сколько места займёт всё, кроме подписи.
  static double chrome({required bool dot, required bool dense}) =>
      (dense ? 9 + 7 : 12 + 10) + (dot ? (dense ? 13 : 18) : 0) + (dense ? 4 + 18 : 6 + 20) + 2.8;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final c = color ?? p.accent;
    // нейтральные плитки (уровень, турниры) — тише цветных
    final edge = on ? c.withValues(alpha: color == null ? .5 : .85) : p.plateLine;
    final check = dense ? 18.0 : 20.0;
    return Semantics(
      checked: on,
      button: true,
      child: Material(
        color: on ? c.withValues(alpha: p.isDark ? .14 : (color == null ? .05 : .07)) : p.plate,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(15),
          side: BorderSide(color: edge, width: 1.4),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 50),
            child: Padding(
              padding: EdgeInsets.fromLTRB(dense ? 9 : 12, 8, dense ? 7 : 10, 8),
              child: Row(
                children: [
                  if (color != null) ...[
                    Container(
                      width: dense ? 7 : 9,
                      height: dense ? 7 : 9,
                      decoration: BoxDecoration(shape: BoxShape.circle, color: c),
                    ),
                    SizedBox(width: dense ? 6 : 9),
                  ],
                  Expanded(
                    child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis, style: styleOf(on, p.ink)),
                  ),
                  SizedBox(width: dense ? 4 : 6),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 140),
                    width: check,
                    height: check,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: on ? c : Colors.transparent,
                      border: Border.all(color: on ? c : p.control, width: 1.4),
                    ),
                    child: on
                        ? Icon(CupertinoIcons.checkmark_alt, size: check * .7, color: p.isDark ? p.bg : Colors.white)
                        : null,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Плитки по две в ряд, равной ширины и высоты. Если слово подписи не помещается
/// в половину ширины даже в узкой плитке — плитки в один столбец: по буквам не переносим.
class TileGrid extends StatelessWidget {
  final List<ChoiceTile> tiles;
  const TileGrid({super.key, required this.tiles});
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      const gap = 8.0;
      final half = (c.maxWidth - gap) / 2;
      double longestWord(ChoiceTile t) => t.label
          .split(' ')
          .map((w) => textWidth(context, w, ChoiceTile.styleOf(true, Colors.black)))
          .fold(0.0, (a, b) => a > b ? a : b);
      bool fits(bool dense) => tiles.every((t) => longestWord(t) <= half - ChoiceTile.chrome(dot: t.color != null, dense: dense));
      final dense = !fits(false);
      final cols = !dense || fits(true) ? 2 : 1;
      final list = [
        for (final t in tiles) ChoiceTile(label: t.label, on: t.on, onTap: t.onTap, color: t.color, dense: dense && cols == 2),
      ];
      final rows = <Widget>[];
      for (var i = 0; i < list.length; i += cols) {
        if (i > 0) rows.add(const SizedBox(height: gap));
        rows.add(
          cols == 1
              ? list[i]
              : IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: list[i]),
                      const SizedBox(width: gap),
                      Expanded(child: i + 1 < list.length ? list[i + 1] : const SizedBox()),
                    ],
                  ),
                ),
        );
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
    },
  );
}

/// Выбор одного из нескольких: ледяная дорожка, выбранное — белая плашка.
/// Подписи одного размера: если не помещаются — уменьшаются все вместе.
class Segmented<T> extends StatelessWidget {
  final List<(T, String)> items;
  final T value;
  final ValueChanged<T>? onChanged;
  const Segmented({super.key, required this.items, required this.value, required this.onChanged});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return LayoutBuilder(
      builder: (context, c) {
        const base = 14.5;
        final seg = (c.maxWidth - 8) / items.length - 10;
        final widest = items
            .map(
              (x) => textWidth(context, x.$2, const TextStyle(fontSize: base, fontWeight: FontWeight.w700, fontFeatures: tnum)),
            )
            .fold(0.0, (a, b) => a > b ? a : b);
        final size = widest > seg ? (base * seg / widest).clamp(11.0, base) : base;
        return Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: p.frost,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: p.plateLine),
          ),
          child: Row(
            children: [
              for (final (v, label) in items)
                Expanded(
                  child: Semantics(
                    selected: v == value,
                    button: true,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: onChanged == null ? null : () => onChanged!(v),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        constraints: const BoxConstraints(minHeight: 40),
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                        decoration: BoxDecoration(
                          color: v == value ? p.plate : Colors.transparent,
                          borderRadius: BorderRadius.circular(11),
                          border: v == value ? Border.all(color: p.accent.withValues(alpha: .55)) : null,
                          boxShadow: v == value && !p.isDark
                              ? [
                                  BoxShadow(
                                    color: Palette.deepBlue.withValues(alpha: .08),
                                    blurRadius: 6,
                                    offset: const Offset(0, 2),
                                  ),
                                ]
                              : null,
                        ),
                        child: Text(
                          label,
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.fade,
                          style: TextStyle(
                            fontSize: size,
                            fontWeight: v == value ? FontWeight.w700 : FontWeight.w500,
                            color: v == value ? p.accent : p.ink2,
                            fontFeatures: tnum,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Квадратный флажок с обводкой не ниже 3:1 к фону.
class SquareCheck extends StatelessWidget {
  final bool on;
  const SquareCheck({super.key, required this.on});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        color: on ? p.accent : Colors.transparent,
        border: Border.all(color: on ? p.accent : p.control, width: 1.6),
      ),
      child: on ? Icon(CupertinoIcons.checkmark_alt, size: 16, color: p.onAccent) : null,
    );
  }
}

// ------------------------------------------------------------------ медали

class Medal extends StatelessWidget {
  final int place;
  final double size;
  const Medal(this.place, {super.key, this.size = 28});

  static const colors = {
    1: [Color(0xFFFBE7A1), Color(0xFFDDB24A), Color(0xFFB0841F)],
    2: [Color(0xFFF6F8FA), Color(0xFFC9D2DB), Color(0xFF8F9CA9)],
    3: [Color(0xFFF5CDAA), Color(0xFFC98A57), Color(0xFF94592C)],
  };
  static const inks = {1: Color(0xFF5E4205), 2: Color(0xFF3A4652), 3: Color(0xFF4F2A0E)};

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final c = colors[place];
    if (c == null) {
      return Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: p.plateLine),
        ),
        child: Text(
          '$place',
          style: TextStyle(fontSize: size * .44, fontWeight: FontWeight.w600, color: p.ink2, fontFeatures: tnum),
        ),
      );
    }
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: c, stops: const [0, .55, 1]),
        border: Border.all(color: Colors.white.withValues(alpha: p.isDark ? .25 : .9), width: 1),
      ),
      child: Text(
        '$place',
        textScaler: TextScaler.noScaling,
        style: TextStyle(fontSize: size * .46, fontWeight: FontWeight.w800, height: 1.0, color: inks[place], fontFeatures: tnum),
      ),
    );
  }
}

// ------------------------------------------------------------------ аватары

/// Круглое фото спортсмена (или инициалы); у пар — два круга внахлёст.
class Avatar extends StatelessWidget {
  final String name;
  final Schedule? data;
  final double size;
  final Color? ring;
  final double ringWidth;

  /// Слот одной ширины для одиночников и пар: имена в столбик ровно.
  final bool slot;
  const Avatar({
    super.key,
    required this.name,
    required this.data,
    this.size = 40,
    this.ring,
    this.ringWidth = 1.5,
    this.slot = false,
  });

  /// Ширина аватара пары: второй круг заходит на первый.
  static double pairWidth(double size) => size * 1.5;

  @override
  Widget build(BuildContext context) {
    final parts = name.split(' / ').map((s) => s.trim()).toList();
    final Widget face = parts.length < 2
        ? _one(context, name, size)
        : SizedBox(
            width: pairWidth(size),
            height: size,
            child: Stack(
              children: [
                Positioned(left: 0, top: 0, child: _one(context, parts[0], size)),
                Positioned(right: 0, top: 0, child: _one(context, parts[1], size)),
              ],
            ),
          );
    if (!slot) return face;
    return SizedBox(
      width: pairWidth(size),
      height: size,
      child: Align(alignment: Alignment.center, child: face),
    );
  }

  Widget _one(BuildContext context, String n, double s) {
    final p = Palette.of(context);
    final url = data?.photoOf(n);
    final fallback = Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: p.isDark ? const [Color(0xFF1C3A5A), Color(0xFF10243A)] : const [Color(0xFFEAF3FC), Color(0xFFCFE1F3)],
        ),
      ),
      child: Text(
        initials(n),
        textScaler: TextScaler.noScaling,
        style: TextStyle(fontSize: s * .36, fontWeight: FontWeight.w700, letterSpacing: .3, color: p.isDark ? p.ink2 : p.accent),
      ),
    );
    return Container(
      width: s,
      height: s,
      padding: EdgeInsets.all(ringWidth),
      decoration: BoxDecoration(shape: BoxShape.circle, color: ring ?? p.plate),
      child: ClipOval(
        child: url == null
            ? fallback
            : Stack(
                fit: StackFit.expand,
                children: [
                  fallback,
                  Transform.scale(
                    scale: 1.32,
                    alignment: const Alignment(0, -.55),
                    child: Image.network(
                      url,
                      fit: BoxFit.cover,
                      alignment: const Alignment(0, -.5),
                      filterQuality: FilterQuality.medium,
                      errorBuilder: (c, e, st) => fallback,
                      frameBuilder: (c, child, frame, sync) => sync
                          ? child
                          : AnimatedOpacity(
                              opacity: frame == null ? 0 : 1,
                              duration: const Duration(milliseconds: 250),
                              child: child,
                            ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

// ------------------------------------------------------------------ нижняя панель

class IceNav extends StatelessWidget {
  final int index;
  final ValueChanged<int> onTap;
  final bool settingsDot;
  const IceNav({super.key, required this.index, required this.onTap, this.settingsDot = false});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    const items = [
      (CupertinoIcons.square_list, CupertinoIcons.square_list_fill, 'Лента'),
      (CupertinoIcons.calendar, CupertinoIcons.calendar_today, 'Месяц'),
      (CupertinoIcons.gear_alt, CupertinoIcons.gear_alt_fill, 'Настройки'),
    ];
    return Container(
      decoration: BoxDecoration(
        color: p.nav,
        border: Border(top: BorderSide(color: p.plateLine, width: 1)),
      ),
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 62),
          child: Row(
            children: [
              for (var i = 0; i < items.length; i++)
                Expanded(
                  child: Semantics(
                    selected: i == index,
                    button: true,
                    child: InkWell(
                      onTap: () => onTap(i),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Stack(
                              clipBehavior: Clip.none,
                              children: [
                                Icon(i == index ? items[i].$2 : items[i].$1, size: 23, color: i == index ? p.accent : p.ink3),
                                if (i == tabSettings && settingsDot)
                                  Positioned(
                                    right: -3,
                                    top: -1,
                                    child: Container(
                                      width: 9,
                                      height: 9,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: p.live,
                                        border: Border.all(color: p.nav, width: 1.5),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              items[i].$3,
                              maxLines: 1,
                              style: TextStyle(
                                fontSize: 12,
                                letterSpacing: .2,
                                fontWeight: i == index ? FontWeight.w700 : FontWeight.w500,
                                color: i == index ? p.accent : p.ink2,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
