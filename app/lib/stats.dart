// «Статистика» в профиле спортсмена (подписка): как менялись баллы от старта к старту, какие
// прыжки исполняются чисто, какие уровни у вращений и дорожек. Счёт — history.dart; здесь только
// вид. Числа — из протоколов ISU и ФФККР с 2018 года и из того, что приложение прочитало само.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'data.dart';
import 'history.dart';
import 'palette.dart';
import 'ui.dart';

/// Откуда берётся история с сайта; в тестах подменяется.
Future<AthleteHistory?> Function(String name) historyLoader = loadHistory;

/// Раздел профиля. [open] — подписка действует; иначе вместо чисел — одна строка о том, что это
/// входит в подписку, и кнопка ([onSubscribe]); нет и её (подписка в сборке не продаётся) — раздела нет.
class StatsSection extends StatefulWidget {
  final String name;
  final Schedule? data;
  final bool open;
  final VoidCallback? onSubscribe;
  const StatsSection({super.key, required this.name, required this.data, required this.open, this.onSubscribe});
  @override
  State<StatsSection> createState() => _StatsSectionState();
}

class _StatsSectionState extends State<StatsSection> {
  Future<AthleteHistory?>? _future;

  /// Сезон («2025/26») или null — все годы.
  String? _season;
  bool _picked = false;
  ScoreKind _kind = ScoreKind.total;

  @override
  void initState() {
    super.initState();
    if (widget.open) _load();
  }

  void _load() => _future = historyLoader(widget.name);

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    if (!widget.open) {
      return Plate(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Баллы по стартам, чистые прыжки и уровни элементов — в подписке',
                style: TextStyle(fontSize: 14.5, color: p.ink2, height: 1.35),
              ),
            ),
            if (widget.onSubscribe != null)
              TextButton(
                onPressed: widget.onSubscribe,
                style: TextButton.styleFrom(foregroundColor: p.accent, minimumSize: const Size(44, 44)),
                child: Text('Подписка', style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: p.accent)),
              ),
          ],
        ),
      );
    }
    return FutureBuilder<AthleteHistory?>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return Plate(
            padding: const EdgeInsets.all(18),
            child: Text('Загружается', style: TextStyle(fontSize: 14.5, color: p.ink2)),
          );
        }
        // то, что приложение знает само, — даже когда сайт не ответил
        final local = widget.data == null ? const <Skate>[] : skatesFromSchedule(widget.data!, widget.name);
        final h = mergeSkates(snap.data, local);
        if (h.twins) {
          return _note(p, 'В протоколах есть полный тёзка: чьи прокаты чьи, не различить. Статистика не считается.');
        }
        if (h.skates.isEmpty) {
          return snap.data == null
              ? _note(p, 'Статистика не загрузилась: нет связи', action: 'Повторить', onAction: () => setState(_load))
              : _note(p, 'Протоколов с его выступлениями нет');
        }
        return _body(context, h, offline: snap.data == null);
      },
    );
  }

  Widget _note(Palette p, String text, {String? action, VoidCallback? onAction}) => Plate(
    padding: EdgeInsets.fromLTRB(18, action == null ? 16 : 6, action == null ? 18 : 6, action == null ? 16 : 6),
    child: Row(
      children: [
        Expanded(child: Text(text, style: TextStyle(fontSize: 14.5, color: p.ink2, height: 1.35))),
        if (action != null)
          TextButton(
            onPressed: onAction,
            style: TextButton.styleFrom(foregroundColor: p.accent, minimumSize: const Size(44, 44)),
            child: Text(action, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: p.accent)),
          ),
      ],
    ),
  );

  Widget _body(BuildContext context, AthleteHistory h, {required bool offline}) {
    final p = Palette.of(context);
    final seasons = ({for (final s in h.skates) s.season}..remove('')).toList()..sort();
    // по умолчанию — последний сезон, где он выступал: «как он сейчас», а не среднее за восемь лет
    if (!_picked) _season = seasons.isEmpty ? null : seasons.last;
    final skates = _season == null ? h.skates : [for (final s in h.skates) if (s.season == _season) s];
    final dance = skates.any((s) => s.kind == 'dance');
    final series = scoreSeries(skates, _kind);
    final jumps = jumpStats(skates);
    final levels = levelStats(skates);
    final falls = fallStats(skates);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (seasons.length > 1 || _season == null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Segmented<String>(
              items: [if (seasons.isNotEmpty) (seasons.last, 'Сезон ${seasons.last}'), ('', 'Все годы')],
              value: _season ?? '',
              onChanged: (v) => setState(() {
                _picked = true;
                _season = v.isEmpty ? null : v;
              }),
            ),
          ),
        Plate(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Segmented<ScoreKind>(
                items: [
                  (ScoreKind.total, 'Сумма'),
                  (ScoreKind.short, dance ? 'Ритм-танец' : 'Короткая'),
                  (ScoreKind.free, dance ? 'Произвольный' : 'Произвольная'),
                ],
                value: _kind,
                onChanged: (v) => setState(() => _kind = v),
              ),
              const SizedBox(height: 14),
              if (series.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  child: Text('Таких баллов в протоколах нет', style: TextStyle(fontSize: 14.5, color: p.ink2)),
                )
              else ...[
                ScoreChart(series: series),
                const SizedBox(height: 10),
                _Legend(series: series),
                const SizedBox(height: 12),
                for (final intl in [true, false])
                  if (series.any((x) => x.skate.intl == intl)) _Best(series: [for (final x in series) if (x.skate.intl == intl) x], intl: intl),
              ],
            ],
          ),
        ),
        if (jumps.isNotEmpty) ...[
          const SizedBox(height: 12),
          Plate(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: _Jumps(jumps: jumps, falls: falls),
          ),
        ],
        if (levels.isNotEmpty) ...[
          const SizedBox(height: 12),
          Plate(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: _Levels(levels: levels),
          ),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 12, 22, 0),
          child: Text(
            [
              'По протоколам ISU и ФФККР с${nb}2018$nbгода: ${skates.length} ${plural(skates.length, 'прокат', 'проката', 'прокатов')}'
                  '${falls.detailed < skates.length ? ', с разбором элементов — ${falls.detailed}' : ''}.',
              'Российские и международные оценки не сравниваются между собой.',
              if (offline) 'Архив не загрузился: показано только то, что есть в расписании.',
            ].join(' '),
            style: TextStyle(fontSize: 12.5, color: p.ink2, height: 1.4),
          ),
        ),
      ],
    );
  }
}

String _dayShort(String day) {
  final d = DateTime.tryParse(day);
  if (d == null) return '';
  return '${d.day}$nb${months[d.month - 1]} ${d.year}';
}

String _pts(double v) => v.toStringAsFixed(2);

/// Цвета двух рядов: международные старты — акцент, российские — тёплый (как у женщин в легенде месяца).
Color _seriesColor(Palette p, bool intl) => intl ? p.accent : p.women;

/// График баллов по стартам: по горизонтали — старты по порядку, по вертикали — баллы. Два ряда —
/// международные и российские — рисуются отдельно: линия соединяет только старты одного ряда.
class ScoreChart extends StatelessWidget {
  final List<ScorePoint> series;
  const ScoreChart({super.key, required this.series});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final first = series.first.skate.day, last = series.last.skate.day;
    return Semantics(
      label: 'График баллов: ${series.length} ${plural(series.length, 'старт', 'старта', 'стартов')}, '
          'от ${_pts(series.map((x) => x.value).reduce(math.min))} до ${_pts(series.map((x) => x.value).reduce(math.max))}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 150,
            child: CustomPaint(painter: _ChartPainter(series, p, Directionality.of(context))),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 44),
                child: Text(_dayShort(first), style: TextStyle(fontSize: 11.5, color: p.ink2)),
              ),
              const Spacer(),
              if (last != first) Text(_dayShort(last), style: TextStyle(fontSize: 11.5, color: p.ink2)),
            ],
          ),
        ],
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  final List<ScorePoint> series;
  final Palette p;
  final TextDirection dir;
  _ChartPainter(this.series, this.p, this.dir);

  @override
  void paint(Canvas canvas, Size size) {
    const left = 44.0, right = 8.0, top = 8.0, bottom = 8.0;
    final values = series.map((x) => x.value);
    var lo = values.reduce(math.min), hi = values.reduce(math.max);
    // одна точка или ровный ряд — поле вокруг, чтобы линия не легла на край
    final pad = math.max((hi - lo) * .12, hi == lo ? math.max(hi * .05, 1) : 0);
    lo -= pad;
    hi += pad;
    final w = size.width - left - right, h = size.height - top - bottom;
    double x(int i) => left + (series.length == 1 ? w / 2 : w * i / (series.length - 1));
    double y(double v) => top + h * (1 - (v - lo) / (hi - lo));

    final grid = Paint()
      ..color = p.line
      ..strokeWidth = 1;
    for (final v in [hi - pad, (hi + lo) / 2, lo + pad]) {
      canvas.drawLine(Offset(left, y(v)), Offset(size.width - right, y(v)), grid);
      final tp = TextPainter(
        text: TextSpan(
          text: v.toStringAsFixed(v >= 100 ? 0 : 1),
          style: TextStyle(fontFamily: sans, fontSize: 11.5, color: p.ink2, fontFeatures: tnum),
        ),
        textDirection: dir,
      )..layout();
      tp.paint(canvas, Offset(left - 8 - tp.width, y(v) - tp.height / 2));
    }
    for (final intl in [false, true]) {
      final color = _seriesColor(p, intl);
      final line = Paint()
        ..color = color
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round;
      final path = Path();
      var started = false;
      for (var i = 0; i < series.length; i++) {
        if (series[i].skate.intl != intl) continue;
        final o = Offset(x(i), y(series[i].value));
        if (started) {
          path.lineTo(o.dx, o.dy);
        } else {
          path.moveTo(o.dx, o.dy);
          started = true;
        }
      }
      canvas.drawPath(path, line);
      for (var i = 0; i < series.length; i++) {
        if (series[i].skate.intl != intl) continue;
        final o = Offset(x(i), y(series[i].value));
        canvas.drawCircle(o, 4, Paint()..color = p.plate);
        canvas.drawCircle(o, 3, Paint()..color = color);
      }
    }
  }

  @override
  bool shouldRepaint(_ChartPainter old) => old.series != series || old.p != p;
}

class _Legend extends StatelessWidget {
  final List<ScorePoint> series;
  const _Legend({required this.series});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Wrap(
      spacing: 14,
      runSpacing: 4,
      children: [
        for (final intl in [true, false])
          if (series.any((x) => x.skate.intl == intl))
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: _seriesColor(p, intl)),
                ),
                const SizedBox(width: 6),
                Text(
                  intl ? 'Международные' : 'Российские',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, color: p.ink2),
                ),
              ],
            ),
      ],
    );
  }
}

/// Лучший и последний результат одного ряда: баллы, турнир, день.
class _Best extends StatelessWidget {
  final List<ScorePoint> series;
  final bool intl;
  const _Best({required this.series, required this.intl});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final best = series.reduce((a, b) => b.value > a.value ? b : a);
    final last = series.last;
    Widget row(String label, ScorePoint x) => Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 86, child: Text(label, style: TextStyle(fontSize: 13.5, color: p.ink2, height: 1.3))),
          SizedBox(
            width: 62,
            child: Text(
              _pts(x.value),
              style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: p.ink, fontFeatures: tnum, height: 1.25),
            ),
          ),
          Expanded(
            child: Text(
              '${x.skate.tournament.isEmpty ? '' : '${x.skate.tournament}\n'}${_dayShort(x.skate.day)}',
              style: TextStyle(fontSize: 13.5, color: p.ink2, height: 1.3),
            ),
          ),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(shape: BoxShape.circle, color: _seriesColor(p, intl)),
              ),
              const SizedBox(width: 6),
              Eyebrow(intl ? 'Международные' : 'Российские'),
            ],
          ),
          row('Лучший', best),
          if (!identical(last.skate, best.skate)) row('Последний', last),
        ],
      ),
    );
  }
}

/// Прыжки: сколько исполнено, сколько чисто, недокруты, рёбра, средняя оценка сольных.
class _Jumps extends StatelessWidget {
  final List<JumpStat> jumps;
  final ({int falls, int skates, int detailed}) falls;
  const _Jumps({required this.jumps, required this.falls});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final head = TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: .2, color: p.ink2);
    final cell = TextStyle(fontSize: 14.5, color: p.ink, fontFeatures: tnum, height: 1.2);
    Widget num(String s, {Color? color, FontWeight? weight}) => Expanded(
      child: Text(s, textAlign: TextAlign.right, style: cell.copyWith(color: color, fontWeight: weight)),
    );
    const good = Color(0xFF2E9E6B), bad = Color(0xFFD0503F);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Eyebrow('Прыжки'),
        const SizedBox(height: 10),
        Row(
          children: [
            const SizedBox(width: 58),
            // «недокр.» — недокруты: слово целиком в колонку не помещается и слипалось с соседним
            for (final t in ['ВСЕГО', 'ЧИСТО', 'НЕДОКР.', 'РЕБРО', 'GOE'])
              Expanded(child: Text(t, textAlign: TextAlign.right, style: head, maxLines: 1, softWrap: false)),
          ],
        ),
        const SizedBox(height: 4),
        for (final j in jumps) ...[
          Container(height: 1, color: p.line, margin: const EdgeInsets.symmetric(vertical: 7)),
          Row(
            children: [
              SizedBox(
                width: 58,
                child: Text(j.jump.replaceAll('Th', '$nbвыбр.'), style: cell.copyWith(fontWeight: FontWeight.w700)),
              ),
              num('${j.done}'),
              // хорошее зелёное, плохое красное; ноль — без цвета
              num('${j.clean}', color: j.clean == j.done ? good : null, weight: FontWeight.w600),
              num(j.under == 0 ? '–' : '${j.under}', color: j.under == 0 ? p.ink3 : bad),
              num(j.edge == 0 ? '–' : '${j.edge}', color: j.edge == 0 ? p.ink3 : bad),
              num(
                j.avgGoe == null ? '–' : '${j.avgGoe! > 0 ? '+' : ''}${j.avgGoe!.toStringAsFixed(2)}',
                color: j.avgGoe == null ? p.ink3 : (j.avgGoe! >= 0 ? good : bad),
              ),
            ],
          ),
        ],
        const SizedBox(height: 12),
        Text(
          [
            'Чисто — без отметок судей на прыжке, без падения и с неотрицательной оценкой элемента.',
            'GOE — средняя надбавка за прыжок вне каскада.',
            'Сорванный прыжок записан в протоколе тем, что исполнено, поэтому «всего» — исполненные, а не задуманные.',
            if (falls.detailed > 0)
              falls.falls == 0
                  ? 'Падений на элементах нет.'
                  : 'Падений на элементах: ${falls.falls}, в ${falls.skates} ${plural(falls.skates, 'прокате', 'прокатах', 'прокатах')} из ${falls.detailed}.',
          ].join(' '),
          style: TextStyle(fontSize: 12.5, color: p.ink2, height: 1.4),
        ),
      ],
    );
  }
}

/// Уровни: по строке на группу элементов, справа «на 4-й уровень N из M» и полоска доли.
class _Levels extends StatelessWidget {
  final List<LevelStat> levels;
  const _Levels({required this.levels});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Eyebrow('Четвёртый уровень'),
        const SizedBox(height: 6),
        for (final l in levels)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Expanded(child: Text(l.group, style: TextStyle(fontSize: 14.5, color: p.ink, height: 1.2))),
                SizedBox(
                  width: 70,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: l.done == 0 ? 0 : l.top / l.done,
                      minHeight: 6,
                      backgroundColor: p.line,
                      valueColor: AlwaysStoppedAnimation(p.accent),
                    ),
                  ),
                ),
                SizedBox(
                  width: 74,
                  child: Text(
                    '${l.top} из ${l.done}',
                    textAlign: TextAlign.right,
                    style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: p.ink, fontFeatures: tnum),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
