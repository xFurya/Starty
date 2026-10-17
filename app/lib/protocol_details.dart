// Раскрытая строка протокола: элементы (база, GOE, оценка), компоненты, сбавки, итоги.
// Оценки судей по каждому элементу и компоненту — по тапу на его строку (на 360 px девять судей в строку не встают).
// Чего нет в файле, того не показываем: ни нулей, ни пустых блоков; пропуск судьи — прочерк на его месте.
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

import 'flags.dart';
import 'palette.dart';
import 'protocol_model.dart';
import 'ui.dart';

/// Расшифровка отметок рядом с элементом; неизвестная отметка остаётся без пояснения.
const markLegend = {
  '<': 'недокрут больше четверти оборота',
  '<<': 'сильный недокрут',
  'q': 'недокрут на четверть оборота',
  'e': 'неверное ребро',
  '!': 'нечёткое ребро',
  '*': 'элемент не засчитан',
  'F': 'падение',
};

/// Названия сбавок из файла по-русски; неизвестное остаётся как в файле.
const _deductionNames = {
  'falls': 'Падения',
  'fall': 'Падения',
  'music tempo': 'Темп музыки',
  'extra element': 'Лишний элемент',
  'extra elements': 'Лишние элементы',
  'time violation': 'Нарушение времени',
  'costume failure': 'Костюм',
  'costume & prop violation': 'Костюм и реквизит',
  'costume and prop violation': 'Костюм и реквизит',
  'prop violation': 'Реквизит',
  'late start': 'Опоздание со стартом',
  'interruption': 'Остановка программы',
  'interruptions': 'Остановка программы',
  'illegal element': 'Запрещённый элемент',
  'illegal elements': 'Запрещённые элементы',
  'illegal movements': 'Запрещённые движения',
  'music violation': 'Нарушение музыки',
  'costume': 'Костюм',
};

String deductionName(String name) => _deductionNames[name.trim().toLowerCase()] ?? name;

/// Номер судьи: «J1» → «С1»; прочее — как в файле.
String judgeLabel(String no) {
  final m = RegExp(r'^[Jj]\s*(\d+)$').firstMatch(no.trim());
  return m == null ? no : 'С${m.group(1)}';
}

/// Отметки элемента по отдельности: «< e» и «<,e» — две отметки.
List<String> marksOf(String info) => [
  for (final m in info.split(RegExp(r'[\s,;]+'))) if (m.isNotEmpty) m,
];

/// GOE со знаком: «+1.21», «-0.40», «0.00».
String goeText(String g) => g.startsWith('-') || g.startsWith('+') || g == '0.00' ? g : '+$g';

/// Оценка судьи: целая (GOE «2») без дробной части, дробная («8.25») с двумя цифрами; null — прочерк.
String markText(num? v) => v == null ? '—' : (v is int ? '$v' : v.toStringAsFixed(2));

class Details extends StatefulWidget {
  final ProtocolRow row;

  /// Судьи сегмента: их номера подписывают оценки; пусто — J1, J2…
  final List<ProtocolJudge> panel;
  const Details({super.key, required this.row, this.panel = const []});

  @override
  State<Details> createState() => _DetailsState();
}

class _DetailsState extends State<Details> {
  final Set<String> _open = {};

  void _toggle(String key) => setState(() => _open.contains(key) ? _open.remove(key) : _open.add(key));

  String _judgeNo(int i) => i < widget.panel.length && widget.panel[i].no.isNotEmpty ? judgeLabel(widget.panel[i].no) : 'С${i + 1}';

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final r = widget.row;
    final k = MediaQuery.textScalerOf(context).scale(1);
    final kids = <Widget>[];

    if (r.elements.isNotEmpty) {
      kids.add(_Head('Элементы', r.bv == null ? null : 'сумма баз ${r.bv}'));
      kids.add(_Table(
        header: const ['', 'Элемент', 'База', 'GOE', 'Оценка'],
        rows: [
          for (var i = 0; i < r.elements.length; i++)
            _TRow(
              key: 'e$i',
              lead: r.elements[i].no == null ? '' : '${r.elements[i].no}',
              name: r.elements[i].name,
              marks: r.elements[i].info,
              cells: [
                r.elements[i].base == null ? '—' : '${r.elements[i].base}${r.elements[i].x ? 'x' : ''}',
                r.elements[i].goe == null ? '—' : goeText(r.elements[i].goe!),
                r.elements[i].score ?? '—',
              ],
              names: const ['база', 'GOE', 'оценка'],
              judges: r.elements[i].judges,
            ),
        ],
        scale: k,
        open: _open,
        onToggle: _toggle,
        judgeNo: _judgeNo,
      ));
      final found = <String>[];
      for (final e in r.elements) {
        for (final m in marksOf(e.info)) {
          if (markLegend.containsKey(m) && !found.contains(m)) found.add(m);
        }
      }
      // «x» — не отметка в файле, а множитель базы: прыжок во второй половине программы
      final hasX = r.elements.any((e) => e.x);
      final legendRows = [
        for (final m in found) (m, markLegend[m]!),
        if (hasX) ('x', 'прыжок во второй половине программы, база ×1,1'),
      ];
      if (legendRows.isNotEmpty) {
        // расшифровка пометок — по одной на строку: знак колонкой, слово рядом
        final legend = TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500, color: p.ink2, height: 1.3);
        kids.add(Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (m, text) in legendRows)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: MediaQuery.textScalerOf(context).scale(22),
                      child: Text(m, style: legend.copyWith(color: p.live, fontWeight: FontWeight.w700)),
                    ),
                    Expanded(child: Text(text, style: legend)),
                  ],
                ),
            ],
          ),
        ));
      }
    }

    if (r.components.isNotEmpty) {
      kids.add(_Head('Компоненты', null));
      kids.add(_Table(
        header: const ['', 'Компонент', 'Коэф.', '', 'Оценка'],
        rows: [
          for (var i = 0; i < r.components.length; i++)
            _TRow(
              key: 'c$i',
              lead: '',
              name: r.components[i].name,
              marks: '',
              cells: [r.components[i].factor == null ? '—' : '×${r.components[i].factor}', '', r.components[i].score ?? '—'],
              names: const ['коэф.', '', 'оценка'],
              judges: r.components[i].judges,
            ),
        ],
        scale: k,
        open: _open,
        onToggle: _toggle,
        judgeNo: _judgeNo,
        hideMiddle: true,
      ));
    }

    if (r.deductions.isNotEmpty) {
      kids.add(_Head('Сбавки', null));
      for (final d in r.deductions) {
        kids.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Expanded(child: Text(deductionName(d.name), style: _name(p))),
              const SizedBox(width: 8),
              Text(d.value ?? '—', style: _val(p)),
            ],
          ),
        ));
      }
    }

    final totals = <(String, String)>[
      if (r.tes != null) ('ТЕХ', r.tes!),
      if (r.pcs != null) ('КОМП', r.pcs!),
      if (r.ded != null) ('Сбавки', r.ded!),
      if (r.points != null) ('Сумма', r.points!),
    ];
    if (totals.isNotEmpty) {
      if (kids.isNotEmpty) kids.add(const SizedBox(height: 10));
      kids.add(Wrap(
        spacing: 18,
        runSpacing: 6,
        children: [
          for (final t in totals)
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.$1, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: p.ink3, letterSpacing: .4)),
                Text(t.$2, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: p.ink, fontFeatures: tnum)),
              ],
            ),
        ],
      ));
    }

    if (kids.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      color: p.bg,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: kids),
    );
  }
}

TextStyle _name(Palette p) => TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.ink, height: 1.25);
TextStyle _val(Palette p) => TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: p.ink, fontFeatures: tnum);

class _Head extends StatelessWidget {
  final String title;
  final String? note;
  const _Head(this.title, this.note);
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Expanded(child: Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: p.ink))),
          if (note != null) Text(note!, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: p.ink2, fontFeatures: tnum)),
        ],
      ),
    );
  }
}

class _TRow {
  final String key, lead, name, marks;
  final List<String> cells, names;
  final List<num?> judges;
  const _TRow({
    required this.key,
    required this.lead,
    required this.name,
    required this.marks,
    required this.cells,
    required this.names,
    required this.judges,
  });
}

/// Таблица из трёх числовых столбцов; когда названию остаётся тесно, числа уходят на вторую строку.
class _Table extends StatelessWidget {
  final List<String> header;
  final List<_TRow> rows;
  final double scale;
  final Set<String> open;
  final void Function(String) onToggle;
  final String Function(int) judgeNo;
  final bool hideMiddle;
  const _Table({
    required this.header,
    required this.rows,
    required this.scale,
    required this.open,
    required this.onToggle,
    required this.judgeNo,
    this.hideMiddle = false,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return LayoutBuilder(
      builder: (context, c) {
        final w1 = 54.0 * scale, w2 = hideMiddle ? 0.0 : 50.0 * scale, w3 = 54.0 * scale, lead = rows.any((r) => r.lead.isNotEmpty) ? 22.0 * scale : 0.0;
        final nameW = c.maxWidth - lead - w1 - w2 - w3;
        final grid = nameW >= 100;
        final hd = TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: p.ink3, letterSpacing: .3);
        Widget numCell(String t, double w, {bool strong = false}) => SizedBox(
          width: w,
          child: Text(t, textAlign: TextAlign.right, style: strong ? _val(p) : _val(p).copyWith(fontWeight: FontWeight.w600, color: p.ink2)),
        );
        return Column(
          children: [
            if (grid)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Row(children: [
                  SizedBox(width: lead),
                  Expanded(child: Text(header[1].toUpperCase(), style: hd)),
                  SizedBox(width: w1, child: Text(header[2].toUpperCase(), textAlign: TextAlign.right, style: hd)),
                  if (!hideMiddle) SizedBox(width: w2, child: Text(header[3].toUpperCase(), textAlign: TextAlign.right, style: hd)),
                  SizedBox(width: w3, child: Text(header[4].toUpperCase(), textAlign: TextAlign.right, style: hd)),
                ]),
              ),
            for (final r in rows) ...[
              Container(
                decoration: BoxDecoration(border: Border(top: BorderSide(color: p.line))),
                child: Semantics(
                  button: r.judges.isNotEmpty,
                  expanded: r.judges.isEmpty ? null : open.contains(r.key),
                  child: InkWell(
                    onTap: r.judges.isEmpty ? null : () => onToggle(r.key),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: grid
                          ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              if (lead > 0) SizedBox(width: lead, child: Text(r.lead, style: _val(p).copyWith(color: p.ink3))),
                              Expanded(child: _nameLine(p, r)),
                              numCell(r.cells[0], w1),
                              if (!hideMiddle) numCell(r.cells[1], w2, strong: true) else const SizedBox.shrink(),
                              numCell(r.cells[2], w3, strong: true),
                            ])
                          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                if (lead > 0) SizedBox(width: lead, child: Text(r.lead, style: _val(p).copyWith(color: p.ink3))),
                                Expanded(child: _nameLine(p, r)),
                                const SizedBox(width: 8),
                                Text(r.cells[2], style: _val(p)),
                              ]),
                              // узко: база и GOE — подписанными значениями под названием, каждое отдельно
                              Padding(
                                padding: EdgeInsets.only(left: lead, top: 2),
                                child: Wrap(
                                  spacing: 14,
                                  runSpacing: 2,
                                  children: [
                                    for (var i = 0; i < 2; i++)
                                      if (r.names[i].isNotEmpty && !(hideMiddle && i == 1))
                                        Text.rich(
                                          TextSpan(
                                            children: [
                                              TextSpan(text: '${r.names[i]}$nb', style: TextStyle(color: p.ink3, fontWeight: FontWeight.w600)),
                                              TextSpan(text: r.cells[i]),
                                            ],
                                          ),
                                          maxLines: 1,
                                          softWrap: false,
                                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: p.ink2, fontFeatures: tnum),
                                        ),
                                  ],
                                ),
                              ),
                            ]),
                    ),
                  ),
                ),
              ),
              if (open.contains(r.key) && r.judges.isNotEmpty)
                Padding(
                  padding: EdgeInsets.only(left: lead, bottom: 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      children: [
                        for (var i = 0; i < r.judges.length; i++)
                          Row(mainAxisSize: MainAxisSize.min, children: [
                            Text(judgeNo(i), style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: p.ink3)),
                            const SizedBox(width: 4),
                            Text(markText(r.judges[i]), style: _val(p)),
                          ]),
                      ],
                    ),
                  ),
                ),
            ],
          ],
        );
      },
    );
  }

  Widget _nameLine(Palette p, _TRow r) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Flexible(
        child: Text.rich(
          TextSpan(children: [
            TextSpan(text: r.name, style: _name(p)),
            if (r.marks.isNotEmpty) TextSpan(text: '  ${r.marks}', style: _name(p).copyWith(color: p.live)),
          ]),
        ),
      ),
      if (r.judges.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(left: 4, top: 2),
          child: Icon(open.contains(r.key) ? CupertinoIcons.chevron_up : CupertinoIcons.chevron_down, size: 11, color: p.ink3),
        ),
    ],
  );
}

/// Судьи сегмента — свёрнутый блок в конце протокола.
class PanelBlock extends StatelessWidget {
  final List<ProtocolJudge> panel;
  final bool open;
  final VoidCallback onTap;
  const PanelBlock({super.key, required this.panel, required this.open, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Plate(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          Semantics(
            button: true,
            expanded: open,
            child: InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 14, 12),
                child: Row(children: [
                  Expanded(
                    child: Text('Судьи', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: p.ink)),
                  ),
                  // сколько судей — числом справа, перед стрелкой
                  Text('${panel.length}', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: p.ink2, fontFeatures: tnum)),
                  const SizedBox(width: 8),
                  Icon(open ? CupertinoIcons.chevron_up : CupertinoIcons.chevron_down, size: 17, color: p.ink3),
                ]),
              ),
            ),
          ),
          if (open)
            for (final j in panel) ...[
              const Hairline(indent: 16),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(
                    width: 36,
                    child: Text(j.no.isEmpty ? '—' : judgeLabel(j.no), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: p.ink3)),
                  ),
                  Expanded(
                    child: Text(
                      j.name.isEmpty ? '—' : protocolName(j.name),
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: p.ink, height: 1.25),
                    ),
                  ),
                  if (j.nation.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    NationTag(j.nation, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, letterSpacing: .6, height: 1.25, color: p.ink2)),
                  ],
                ]),
              ),
            ],
        ],
      ),
    );
  }
}
