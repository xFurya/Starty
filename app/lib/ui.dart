// Оформление «Лёд»: шрифты, слова, плашки, фото-шапка, аватары, медали, кнопки, нижняя панель.
import 'dart:math' as math;

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

/// Буква для круга без фото: первая буква фамилии.
String initialOf(String name) {
  final s = surname(name).trim();
  return s.isEmpty ? '' : s[0].toUpperCase();
}

/// Пары — фамилиями, одиночники — «А. Заикина».
String initialName(String name) {
  if (name.contains(' / ')) return surname(name);
  final full = displayName(name).split(RegExp(r'\s+'));
  final last = surname(name);
  final first = full.firstWhere((w) => w != last, orElse: () => '');
  return first.isEmpty ? last : '${first[0]}. $last';
}

String placingName(Placing x) => initialName(x.name);

/// Как вывести имя по строкам — варианты от полного к короткому. Пара никогда не теряет
/// партнёра: либо оба в строку, либо по партнёру на строку («Рыбакова /», «Махноносов»).
/// [full] — начинать с полного имени; [initial] — у одиночника вариант «А. Заикина»;
/// [lines] — сколько строк можно занять.
List<List<String>> nameVariants(String name, {bool full = true, bool initial = false, int lines = 1}) {
  final parts = displayName(name).split(' / ').map((x) => x.trim()).toList();
  final sur = surname(name).split(' / ').map((x) => x.trim()).toList();
  List<String> stacked(List<String> xs) => [for (var i = 0; i < xs.length; i++) i < xs.length - 1 ? '${xs[i]} /' : xs[i]];
  final out = <List<String>>[];
  if (parts.length > 1) {
    if (full) {
      out.add([parts.join(' / ')]);
      if (lines >= parts.length) out.add(stacked(parts));
    }
    out.add([sur.join(' / ')]);
    if (lines >= sur.length) out.add(stacked(sur));
  } else {
    final words = parts.first.split(RegExp(r'\s+'));
    if (full) out.add([parts.first]);
    if (initial) out.add([initialName(name)]);
    if (full && !initial && lines >= 2 && words.length > 1) {
      out.add([words.sublist(0, words.length - 1).join(' '), words.last]);
    }
    out.add([sur.first]);
  }
  final seen = <String>{};
  return [
    for (final v in out)
      if (seen.add(v.join('\n'))) v,
  ];
}

/// Варианты только с полными именами (без «А. Заикина» и фамилий).
List<List<String>> fullVariants(String name, {int lines = 1}) {
  final short = {for (final v in nameVariants(name, full: false, initial: true, lines: lines)) v.join('\n')};
  return [
    for (final v in nameVariants(name, lines: lines))
      if (!short.contains(v.join('\n'))) v,
  ];
}

/// Формат имён один на весь список: полные — только если полное имя помещается у каждого.
/// [width] — место под имя, [suffix] — ширина подписи справа от имени у каждого.
bool allFull(BuildContext context, List<String> names, TextStyle style, double width, {int lines = 2, double Function(int i)? suffix}) {
  for (var i = 0; i < names.length; i++) {
    final sw = suffix?.call(i) ?? 0;
    if (!fullVariants(names[i], lines: lines).any((v) => NameLines.fits(context, v, style, width, sw))) return false;
  }
  return true;
}

/// Тесно: узкий экран или крупный шрифт.
bool tight(BuildContext context) =>
    MediaQuery.sizeOf(context).width < 360 || MediaQuery.textScalerOf(context).scale(10) > 11;

/// Код страны на экране: нейтральный статус — «AIN».
String nationCode(String n) => n.startsWith('AIN') ? 'AIN' : n;

/// Неразрывный пробел: «1 ч», «в 17:30» не разрываются.
const nb = '\u00A0';

/// «через 1 ч 50 мин»; меньше минуты — «через минуту». Одной строкой, без переносов.
String countdown(Duration d) {
  final m = (d.inSeconds / 60).ceil();
  if (m <= 1) return 'через$nbминуту';
  final h = m ~/ 60, r = m % 60;
  if (h == 0) return 'через$nb$r$nbмин';
  return r == 0 ? 'через$nb$h$nbч' : 'через$nb$h$nbч$nb$r$nbмин';
}

/// Когда начало: сегодня — отсчёт, завтра — «завтра в 17:30», дальше — дата.
String whenLabel(Start s, DateTime t) {
  if (s.day == dayKey(t)) return countdown(s.t0.difference(t));
  if (s.day == dayKey(t.add(const Duration(days: 1)))) return 'завтра$nbв$nb${hm(s.t0)}';
  final d = msk(s.t0);
  return '${d.day}$nb${months[d.month - 1]}';
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

/// Подпись раздела: мелкие прописные. Цвет по умолчанию — ink2: не ниже 4.5:1 к фону и плашке.
class Eyebrow extends StatelessWidget {
  final String text;
  final Color? color;
  final EdgeInsets padding;
  final Widget? trailing;

  /// Название турнира не обрезаем: в шапке листа и в плашке дня — до двух строк.
  final int maxLines;
  const Eyebrow(this.text, {super.key, this.color, this.padding = EdgeInsets.zero, this.trailing, this.maxLines = 1});

  static TextStyle style(Color color) =>
      TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, letterSpacing: 1.3, height: 1.3, color: color);

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final label = Text(text.toUpperCase(), maxLines: maxLines, overflow: TextOverflow.ellipsis, style: style(color ?? p.ink2));
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
    // полоса над подписью в шапке листа (см. SheetSparkles)
    [(.66, .50, 9.0), (.88, .30, 5.5), (.42, .70, 3.5)],
  ];

  /// Вариант для полосы над подписью листа.
  static const band = 4;

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

/// Искры шапки листа: полоса над подписью турнира, правее ручки. На текст не ложатся,
/// какой бы длинной ни была подпись.
class SheetSparkles extends StatelessWidget {
  const SheetSparkles({super.key});
  static const height = 34.0;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return LayoutBuilder(
      builder: (context, c) => Padding(
        padding: EdgeInsets.only(left: c.maxWidth / 2 + 30),
        child: SizedBox(
          height: height,
          width: double.infinity,
          child: CustomPaint(
            painter: SparklePainter(
              p.isDark ? Colors.white : Palette.iceBlue,
              p.isDark ? .85 : .45,
              variant: SparklePainter.band,
            ),
          ),
        ),
      ),
    );
  }
}

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
              // узкая кнопка на узком экране: поля меньше, надпись в одну строку
              padding: EdgeInsets.symmetric(horizontal: compact ? (MediaQuery.sizeOf(context).width < 360 ? 14 : 20) : 14),
              child: Row(
                mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (icon != null) ...[Icon(icon, size: 19, color: fg), const SizedBox(width: 8)],
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
    // приглушённый, но различимый: не ниже 3:1 к плашке
    return Semantics(
      label: 'Без уведомления',
      child: Icon(CupertinoIcons.bell_slash, size: size, color: p.control),
    );
  }
}

/// LayoutBuilder, который пересобирается, когда догрузились шрифты: в вебе шрифты
/// приходят после первого кадра, и замер текста до этого — по чужому шрифту.
class MeasuredLayout extends StatefulWidget {
  final Widget Function(BuildContext, BoxConstraints) builder;
  const MeasuredLayout({super.key, required this.builder});
  @override
  State<MeasuredLayout> createState() => _MeasuredLayoutState();
}

class _MeasuredLayoutState extends State<MeasuredLayout> {
  void _fonts() => setState(() {});
  @override
  void initState() {
    super.initState();
    PaintingBinding.instance.systemFonts.addListener(_fonts);
  }

  @override
  void dispose() {
    PaintingBinding.instance.systemFonts.removeListener(_fonts);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: widget.builder);
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

/// Заголовок с кнопкой справа: если самое длинное слово заголовка не помещается рядом
/// с кнопкой (слово порвалось бы по буквам) — кнопку ставят под заголовок.
bool actionBelow(BuildContext context, double width, String title, TextStyle titleStyle, String action, TextStyle actionStyle) {
  final word = title.split(RegExp(r'\s+')).map((w) => textWidth(context, w, titleStyle)).fold(0.0, math.max);
  // у кнопки поля 12 слева и справа, зазор 8
  return word > width - textWidth(context, action, actionStyle) - 24 - 8;
}

/// Имя по строкам (см. [nameVariants]): берётся первый вариант, который помещается целиком,
/// вместе с подписью справа ([suffix] — код страны, «разминка 2»; она не сжимается).
/// Не поместился ни один — строки последнего варианта уменьшаются, а не рвутся по буквам.
class NameLines extends StatelessWidget {
  final List<List<String>> variants;
  final TextStyle style;
  final String suffix;
  final TextStyle? suffixStyle;
  final bool center;

  /// Что прочтёт экранный диктор: имя целиком.
  final String? semantics;
  const NameLines({
    super.key,
    required this.variants,
    required this.style,
    this.suffix = '',
    this.suffixStyle,
    this.center = false,
    this.semantics,
  });

  static const gap = 6.0;

  /// Помещается ли вариант в ширину [w] вместе с подписью [suffixW] после последней строки.
  static bool fits(BuildContext context, List<String> v, TextStyle style, double w, [double suffixW = 0]) {
    for (var i = 0; i < v.length; i++) {
      if (textWidth(context, v[i], style) + (i == v.length - 1 ? suffixW : 0) > w + .5) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) => MeasuredLayout(
    builder: (context, c) {
      final w = c.maxWidth;
      final sw = suffix.isEmpty ? 0.0 : textWidth(context, suffix, suffixStyle ?? style) + gap;
      final pick = variants.firstWhere((v) => fits(context, v, style, w, sw), orElse: () => variants.last);
      final shrink = !fits(context, pick, style, w, sw);
      Widget line(String t, bool last) {
        Widget text = Text(t, maxLines: 1, softWrap: false, overflow: TextOverflow.clip, style: style);
        if (shrink) {
          text = FittedBox(
            fit: BoxFit.scaleDown,
            alignment: center ? Alignment.center : Alignment.centerLeft,
            child: text,
          );
        }
        if (!last || suffix.isEmpty) return text;
        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: shrink ? CrossAxisAlignment.end : CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Flexible(child: text),
            const SizedBox(width: gap),
            Text(suffix, maxLines: 1, softWrap: false, style: suffixStyle ?? style),
          ],
        );
      }

      final body = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: center ? CrossAxisAlignment.center : CrossAxisAlignment.start,
        children: [for (var i = 0; i < pick.length; i++) line(pick[i], i == pick.length - 1)],
      );
      if (semantics == null) return body;
      return Semantics(
        label: suffix.isEmpty ? semantics : '$semantics $suffix',
        child: ExcludeSemantics(child: body),
      );
    },
  );
}

/// Плитка выбора: цветная точка (необязательно), подпись, галочка. Равные плитки сеткой.
class ChoiceTile extends StatelessWidget {
  final String label;
  final bool on;
  final Color? color;
  final VoidCallback? onTap;

  /// Узкая плитка: поля и значки меньше.
  final bool dense;
  final double fontSize;

  /// Подпись из одного слова не помещается и при самом мелком кегле — уменьшить её, а не рвать.
  final bool fitLabel;
  const ChoiceTile({
    super.key,
    required this.label,
    required this.on,
    required this.onTap,
    this.color,
    this.dense = false,
    this.fontSize = 14.5,
    this.fitLabel = false,
  });

  /// Начертание одно и то же — выбранная плитка не становится шире.
  static TextStyle styleOf(double size, Color ink) =>
      TextStyle(fontSize: size, height: 1.2, fontWeight: FontWeight.w600, color: ink);

  /// Сколько места займёт всё, кроме подписи.
  static double chrome({required bool dot, required bool dense}) =>
      (dense ? 8 + 6 : 12 + 10) + (dot ? (dense ? 11 : 18) : 0) + (dense ? 4 + 16 : 6 + 20) + 2.8 + 2;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final c = color ?? p.accent;
    // нейтральные плитки (уровень, турниры) — тише цветных
    final edge = on ? c.withValues(alpha: color == null ? .5 : .85) : p.plateLine;
    final check = dense ? 16.0 : 20.0;
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
              padding: EdgeInsets.fromLTRB(dense ? 8 : 12, 8, dense ? 6 : 10, 8),
              child: Row(
                children: [
                  if (color != null) ...[
                    Container(
                      width: dense ? 6 : 9,
                      height: dense ? 6 : 9,
                      decoration: BoxDecoration(shape: BoxShape.circle, color: c),
                    ),
                    SizedBox(width: dense ? 5 : 9),
                  ],
                  Expanded(
                    child: fitLabel
                        ? FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text(label, maxLines: 1, softWrap: false, style: styleOf(fontSize, p.ink)),
                          )
                        : Text(label, maxLines: 2, overflow: TextOverflow.ellipsis, style: styleOf(fontSize, p.ink)),
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

/// Плитки по две в ряд, равной ширины и высоты — всегда, и для видов 2×2, и для пар плиток.
/// Плотность и кегль считаются по [group] — по всем плиткам карточки, чтобы в одной карточке
/// плитки были одного вида. Слово подписи не помещается — плитка уже, затем кегль мельче;
/// по буквам не переносим.
class TileGrid extends StatelessWidget {
  final List<ChoiceTile> tiles;

  /// Все плитки карточки (по умолчанию — только свои).
  final List<ChoiceTile>? group;
  const TileGrid({super.key, required this.tiles, this.group});

  /// Слова подписи: перенос возможен по пробелу и после дефиса («ритм-/танец»).
  static List<String> words(String label) => label.split(RegExp(r'\s+|(?<=-)')).where((w) => w.isNotEmpty).toList();

  @override
  Widget build(BuildContext context) => MeasuredLayout(
    builder: (context, c) {
      const gap = 8.0;
      final all = group ?? tiles;
      final half = (c.maxWidth - gap) / 2;
      double longestWord(ChoiceTile t, double size) => words(t.label)
          .map((w) => textWidth(context, w, ChoiceTile.styleOf(size, Colors.black)))
          .fold(0.0, (a, b) => a > b ? a : b);
      double room(ChoiceTile t, bool dense) => half - ChoiceTile.chrome(dot: t.color != null, dense: dense);
      bool fits(bool dense, double size) => all.every((t) => longestWord(t, size) <= room(t, dense));
      // по порядку: обычная плитка, узкая, узкая и на пункт мельче, ещё мельче — по самому тесному слову
      late bool dense;
      late double size;
      if (fits(false, 14.5)) {
        (dense, size) = (false, 14.5);
      } else if (fits(true, 14.5)) {
        (dense, size) = (true, 14.5);
      } else if (fits(true, 13.5)) {
        (dense, size) = (true, 13.5);
      } else {
        var k = 1.0;
        for (final t in all) {
          k = math.min(k, room(t, true) / math.max(1, longestWord(t, 13)));
        }
        dense = true;
        size = math.max(10.0, (13 * k * .98 * 10).floorToDouble() / 10);
      }
      final list = [
        for (final t in tiles)
          ChoiceTile(
            label: t.label,
            on: t.on,
            onTap: t.onTap,
            color: t.color,
            dense: dense,
            fontSize: size,
            fitLabel: words(t.label).length == 1 && longestWord(t, size) > room(t, dense),
          ),
      ];
      final rows = <Widget>[];
      for (var i = 0; i < list.length; i += 2) {
        if (i > 0) rows.add(const SizedBox(height: gap));
        rows.add(
          IntrinsicHeight(
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
/// Подписи одного размера: если не помещаются — уменьшаются все вместе; не обрезаются никогда.
class Segmented<T> extends StatelessWidget {
  final List<(T, String)> items;
  final T value;
  final ValueChanged<T>? onChanged;
  const Segmented({super.key, required this.items, required this.value, required this.onChanged});

  static const base = 14.5;

  /// Кегль (до масштаба шрифта), при котором самая широкая подпись помещается в сегмент
  /// дорожки шириной [width]. Меньше [minFont] — пора на короткие подписи.
  static double fontFor(BuildContext context, double width, List<String> labels) {
    // дорожка: окантовка и поля 8, у сегмента — поля 8 и рамка выбранного 2, плюс запас
    final seg = (width - 8) / labels.length - 13;
    final widest = labels
        .map((x) => textWidth(context, x, const TextStyle(fontSize: base, fontWeight: FontWeight.w700, fontFeatures: tnum)))
        .fold(0.0, (a, b) => a > b ? a : b);
    return widest > seg ? base * seg / widest : base;
  }

  static const minFont = 12.0;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return MeasuredLayout(
      builder: (context, c) {
        final size = fontFor(context, c.maxWidth, [for (final x in items) x.$2]);
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
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            label,
                            maxLines: 1,
                            softWrap: false,
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

/// Круглое фото спортсмена (или буква фамилии); у пар — два круга внахлёст,
/// у пары без обоих фото — один круг.
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
    final noPhotos = parts.length > 1 && parts.every((x) => data?.photoOf(x) == null);
    final Widget face = parts.length < 2 || noPhotos
        ? _one(context, name, size, pair: noPhotos)
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

  Widget _one(BuildContext context, String n, double s, {bool pair = false}) {
    final p = Palette.of(context);
    final url = pair ? null : data?.photoOf(n);
    final ink = p.isDark ? p.ink2 : p.accent;
    // без фото — лёд и одна буква фамилии антиквой; у пары — значок пары
    final fallback = Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: p.isDark ? const [Color(0xFF1C3A5A), Color(0xFF10243A)] : const [Color(0xFFEAF3FC), Color(0xFFCFE1F3)],
        ),
      ),
      child: pair
          ? Icon(CupertinoIcons.person_2_fill, size: s * .46, color: ink.withValues(alpha: .7))
          : Padding(
              padding: EdgeInsets.only(bottom: s * .04),
              child: Text(
                initialOf(n),
                textScaler: TextScaler.noScaling,
                style: TextStyle(fontFamily: serif, fontSize: s * .52, fontWeight: FontWeight.w600, height: 1, color: ink),
              ),
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
