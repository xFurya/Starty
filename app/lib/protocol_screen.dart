// Протокол турнира в приложении: категория → сегмент (короткая, произвольная, итог) → строки.
// Данные — из файла протокола (protocol_model.dart); оригинал табло — значком в верхней панели, во встроенном браузере.
// Честность: число показываем только если оно есть в файле, окончательность — только по судейским оценкам.
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

import 'data.dart';
import 'live.dart' show LiveOk, personKey;
import 'palette.dart';
import 'protocol_model.dart';
import 'protocol_details.dart';
import 'protocol.dart' show openOriginal;
import 'protocol_repo.dart';
import 'state.dart' show AppState;
import 'ui.dart';

/// Подписи вкладок сегментов: короткие, чтобы три вкладки умещались в ширину 360 px.
const _tabLabel = {'КП': 'Короткая', 'ПП': 'Произвольная', 'РТ': 'Ритм-танец', 'ПТ': 'Произвольный'};
const totalTab = 'итог';

/// Цвет строки статуса: окончательный — акцент, идущий — цвет живого, остальное — приглушённый.
enum ProtocolTone { finalized, live, quiet }

/// Что показать под переключателем: текст статуса, список и кнопку «Повторить».
class ProtocolView {
  final String status;
  final ProtocolTone tone;
  final bool retry;

  /// Строки из файла (места, баллы).
  final List<ProtocolRow> rows;

  /// Состав по заявке (без мест и баллов) — когда протокола ещё нет.
  final bool application;

  /// В файле для этого сегмента нет строк (протокола ещё нет) — можно показать живые итоги с табло.
  final bool noFile;
  const ProtocolView(
    this.status,
    this.tone, {
    this.retry = false,
    this.rows = const [],
    this.application = false,
    this.noFile = false,
  });
}

/// Текст статуса по загрузке файла, категории и вкладке. Все тексты — из утверждённых макетов.
/// [category] — категория из файла (той же загрузки, что и [load], или из кэша); null — её нет.
ProtocolView protocolView(
  ProtocolLoad load, {
  required ProtocolCategory? category,
  required String tab,
  required bool hasField,
  DateTime? built,
  int fieldCount = 0,
}) {
  // Любой сбой при наличии сохранённого файла — сохранённая версия; без него — короткий текст
  // (экран в этом случае не открывается, сразу открывается оригинал, см. [ProtocolScreen]).
  final (cached, cachedAt) = savedOf(load);
  if (cached != null && cachedAt != null) {
    final v = _inFile(category, tab, hasField: hasField, built: cached.built, fieldCount: fieldCount);
    // сохранённая версия: строки есть, но статус — что связи нет и когда файл сохранён
    // «Нет связи» — только для сетевого сбоя; при 404, битом файле и чужой версии связь ни при чём
    final saved = '${_dm(cachedAt)}, ${hm(cachedAt)}';
    return ProtocolView(
      load is ProtocolNetError ? 'Нет связи · сохранено $saved' : 'Показана сохранённая версия · $saved',
      ProtocolTone.quiet,
      retry: true,
      rows: v.rows,
      application: v.application,
      noFile: v.noFile,
    );
  }
  switch (load) {
    case ProtocolFormatError():
      return const ProtocolView('Экран для этого протокола недоступен', ProtocolTone.quiet);
    case ProtocolMissing():
      return _noProtocol(hasField);
    case ProtocolNetError():
      return const ProtocolView('Нет связи с сервером', ProtocolTone.quiet, retry: true);
    case ProtocolOk():
      return _inFile(category, tab, hasField: hasField, built: built, fieldCount: fieldCount);
  }
}

/// Сохранённая версия файла и время её сохранения при любом сбое загрузки; (null, null) — её нет или загрузка удалась.
(ProtocolDoc?, DateTime?) savedOf(ProtocolLoad load) => switch (load) {
  ProtocolNetError(:final cached, :final cachedAt) => (cached, cachedAt),
  ProtocolMissing(:final cached, :final cachedAt) => (cached, cachedAt),
  ProtocolFormatError(:final cached, :final cachedAt) => (cached, cachedAt),
  ProtocolOk() => (null, null),
};

ProtocolView _noProtocol(bool hasField) => hasField
    ? const ProtocolView('Протокола пока нет · состав по заявке', ProtocolTone.quiet, application: true, noFile: true)
    : const ProtocolView('Протокола и заявки пока нет', ProtocolTone.quiet, noFile: true);

ProtocolView _inFile(ProtocolCategory? category, String tab, {required bool hasField, DateTime? built, int fieldCount = 0}) {
  if (category == null) return _noProtocol(hasField);
  if (tab == totalTab) {
    final t = category.total;
    if (t == null || t.state == TotalState.notPublished) {
      return const ProtocolView('Итог вида ещё не опубликован', ProtocolTone.quiet);
    }
    if (t.state == TotalState.format) return const ProtocolView('Экран для этого протокола недоступен', ProtocolTone.quiet);
    if (t.state == TotalState.finalized) {
      return ProtocolView('Окончательный', ProtocolTone.finalized, rows: t.rows);
    }
    return ProtocolView(_updated(built), ProtocolTone.quiet, rows: t.rows);
  }
  final seg = category.segmentOf(tab);
  if (seg == null) return _noProtocol(hasField);
  switch (seg.state) {
    case SegmentState.scheduled:
    case SegmentState.notPublished:
      return _noProtocol(hasField);
    case SegmentState.inProgress:
      if (seg.rows.isEmpty) return _noProtocol(hasField);
      // «9 из 14»: сколько выступило — только если известен весь состав
      final n = seg.rows.length;
      final of = fieldCount >= n ? ' · $n из $fieldCount' : '';
      return ProtocolView('Идёт$of · ${_updated(built)}', ProtocolTone.live, rows: seg.rows);
    case SegmentState.provisional:
      if (seg.rows.isEmpty) return _noProtocol(hasField);
      return ProtocolView(_updated(built), ProtocolTone.quiet, rows: seg.rows);
    case SegmentState.finalized:
      // окончательный без строк — нераспознанный файл, а не «протокол пуст»
      if (seg.rows.isEmpty) return const ProtocolView('Экран для этого протокола недоступен', ProtocolTone.quiet);
      return ProtocolView('Окончательный', ProtocolTone.finalized, rows: seg.rows);
    case SegmentState.judgesMismatch:
      return const ProtocolView('Итоги не подтверждены', ProtocolTone.quiet);
    case SegmentState.format:
      return const ProtocolView('Экран для этого протокола недоступен', ProtocolTone.quiet);
  }
}

/// Подписи колонок итога по-русски (КП, ПП, РТ, ПТ); незнакомая остаётся как в файле.
String colLabel(String c) {
  final t = c.trim().toUpperCase();
  const en = {'SP': 'КП', 'FS': 'ПП', 'RD': 'РТ', 'FD': 'ПТ', 'PT': 'РТ'};
  if (en.containsKey(t)) return en[t]!;
  // латинские двойники кириллических букв (KП, PТ)
  const twin = {'K': 'К', 'P': 'Р', 'T': 'Т', 'H': 'Н', 'C': 'С', 'E': 'Е', 'A': 'А', 'O': 'О', 'X': 'Х', 'M': 'М', 'B': 'В'};
  final cyr = t.split('').map((ch) => twin[ch] ?? ch).join();
  return const {'КП', 'ПП', 'РТ', 'ПТ'}.contains(cyr) ? cyr : c;
}

/// Статус участника без места по-русски; незнакомый остаётся как в файле.
String statusLabel(String s) {
  const m = {
    'WD': 'снят',
    'DNS': 'не вышел',
    'DQ': 'дисквалифицирован',
    'RET': 'прервал',
    'NQ': 'не допущен',
    'NQD': 'не прошёл',
    'UNR': 'без места',
    'NP': 'без места',
  };
  return m[s.trim().toUpperCase()] ?? s;
}

String _updated(DateTime? built) => built == null ? 'Обновлено' : 'Обновлено ${hm(built)}';

String _dm(DateTime t) {
  final m = msk(t);
  return '${two(m.day)}.${two(m.month)}';
}

/// Подпись категории для переключателя: «Девушки · Юниоры».
String categoryLabel(ProtocolCategory c) {
  final kind = kindNames[c.kind] ?? c.kind;
  final young = {'women': 'Девушки', 'men': 'Юноши'}[c.kind];
  final k = young != null && c.level == 'junior' ? young : kind;
  return '$k · ${levelNames[c.level] ?? c.level}';
}

/// Адрес «Оригинала протокола»: страница сегмента на табло, иначе — оглавление.
String originalUrl(ProtocolDoc? doc, ProtocolSegment? seg, Start s) {
  if (seg != null && seg.page.isNotEmpty) return seg.page;
  if (doc != null && doc.src.isNotEmpty) return doc.src;
  return s.src;
}

class ProtocolScreen extends StatefulWidget {
  final Start start;

  /// Для тестов; в приложении — общий репозиторий.
  final ProtocolRepo? repo;

  /// Открытие оригинала; в тестах подменяется. В приложении — встроенный браузер (см. [openOriginal]).
  final Future<void> Function(String url)? opener;

  /// Состояние приложения: живые итоги с табло, если в файле у сегмента строк ещё нет.
  final AppState? state;
  const ProtocolScreen({super.key, required this.start, this.repo, this.opener, this.state});

  @override
  State<ProtocolScreen> createState() => _ProtocolScreenState();
}

class _ProtocolScreenState extends State<ProtocolScreen> {
  ProtocolLoad? _load;
  bool _busy = false;
  String? _catKey, _tab;
  final Set<String> _open = {};
  bool _panelOpen = false;

  ProtocolRepo get _repo => widget.repo ?? ProtocolRepo.app;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final proto = widget.start.proto;
    setState(() => _busy = true);
    final load = proto == null ? const ProtocolMissing() : await _repo.load(proto);
    if (!mounted) return;
    // Нет ни свежего файла, ни сохранённого: наш экран показать нечего — открываем оригинал и уходим.
    if (load is! ProtocolOk && savedOf(load).$1 == null && widget.start.src.isNotEmpty) {
      setState(() => _busy = false);
      try {
        if (widget.opener case final o?) {
          await o(widget.start.src);
          if (mounted) Navigator.of(context).maybePop();
        } else {
          await openOriginal(context, widget.start.src, widget.start.tournament, replace: true);
        }
      } catch (_) {}
      return;
    }
    setState(() {
      _load = load;
      _busy = false;
      _pickDefaults();
    });
  }

  /// Файл протокола, который показываем: свежий или сохранённый (при сбое сети).
  ProtocolDoc? get _doc => switch (_load) {
    ProtocolOk(:final doc) => doc,
    final ProtocolLoad l => savedOf(l).$1,
    null => null,
  };

  List<ProtocolCategory> get _cats => _doc?.categories ?? const [];

  ProtocolCategory? get _category {
    final cats = _cats;
    for (final c in cats) {
      if ('${c.kind}|${c.level}' == _catKey) return c;
    }
    return null;
  }

  /// Выбор по умолчанию: категория и вкладка старта; уже выбранное сохраняем, если оно есть в файле.
  void _pickDefaults() {
    final s = widget.start;
    final cats = _cats;
    if (cats.isEmpty) {
      _catKey = null;
      _tab = null;
      return;
    }
    if (_category == null) {
      final match = _doc?.categoryFor(s.kind, s.level) ?? cats.first;
      _catKey = '${match.kind}|${match.level}';
    }
    final c = _category!;
    if (_tab == null || (_tab != totalTab && c.segmentOf(_tab!) == null)) {
      _tab = c.segmentOf(s.seg) != null ? s.seg : (c.segments.isNotEmpty ? c.segments.first.code : totalTab);
    }
  }

  Future<void> _pickCategory() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
          children: [
            for (final cat in _cats)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: ChoiceTile(
                  label: categoryLabel(cat),
                  on: '${cat.kind}|${cat.level}' == _catKey,
                  onTap: () => Navigator.of(c).pop('${cat.kind}|${cat.level}'),
                ),
              ),
          ],
        ),
      ),
    );
    if (picked != null && mounted) {
      setState(() {
        _catKey = picked;
        _tab = null;
        _pickDefaults();
      });
    }
  }

  Future<void> _openOrig(String url) async {
    if (url.isEmpty) return;
    try {
      await (widget.opener ?? (u) => openOriginal(context, u, widget.start.tournament))(url);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    if (state == null) return _build(context, null);
    return ListenableBuilder(listenable: state, builder: (c, _) => _build(c, state.liveOf(widget.start.id)));
  }

  Widget _build(BuildContext context, LiveOk? live) {
    final s = widget.start;
    final doc = _doc;
    final cat = _category;
    final tab = _tab ?? totalTab;
    final seg = tab == totalTab ? null : cat?.segmentOf(tab);
    final hasField = s.field.isNotEmpty;
    final load = _load;
    var view = load == null
        ? const ProtocolView('Загружаем протокол…', ProtocolTone.quiet)
        : protocolView(load, category: cat, tab: tab, hasField: hasField, built: doc?.built, fieldCount: s.field.length);
    // В файле строк нет, а табло уже показало итоги этого старта — показываем их, пока файл не обновится.
    final onBoard = live != null &&
        live.rows.isNotEmpty &&
        view.noFile &&
        tab == s.seg &&
        (cat == null || (cat.kind == s.kind && cat.level == s.level));
    if (onBoard) {
      final n = live.rows.length;
      final of = s.field.length >= n ? ' · $n из ${s.field.length}' : '';
      view = ProtocolView(
        'По табло$of · элементов и оценок судей пока нет',
        live.provisional ? ProtocolTone.live : ProtocolTone.quiet,
        rows: [
          for (var i = 0; i < live.rows.length; i++)
            ProtocolRow(i: i + 1, place: live.rows[i].place, name: live.rows[i].name, nation: live.rows[i].nation, points: live.rows[i].points),
        ],
      );
    }
    final cats = _cats;
    final tabs = cat == null
        ? const <(String, String)>[]
        : [
            for (final x in cat.segments) (x.code, _tabLabel[x.code] ?? x.name),
            (totalTab, 'Итог'),
          ];
    final ours = {for (final o in s.ours) personKey(o.name)};
    final width = MediaQuery.sizeOf(context).width;
    final gutter = width < 360 ? 12.0 : 16.0;

    return Scaffold(
      appBar: AppBar(
        title: Text(s.tournament, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17)),
        actions: [
          if (originalUrl(doc, seg, s).isNotEmpty)
            IconButton(
              tooltip: 'Оригинал протокола',
              icon: const Icon(CupertinoIcons.globe),
              onPressed: () => _openOrig(originalUrl(doc, seg, s)),
            ),
          IconButton(
            tooltip: 'Обновить',
            icon: const Icon(Icons.refresh),
            onPressed: _busy ? null : _reload,
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          // на широком окне (Windows) контент не растягивается на всю ширину
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: EdgeInsets.fromLTRB(gutter, 4, gutter, 28 + MediaQuery.paddingOf(context).bottom),
            children: [
              if (cats.length == 2)
                Segmented<String>(
                  items: [for (final c in cats) ('${c.kind}|${c.level}', categoryLabel(c))],
                  value: _catKey ?? '',
                  onChanged: (v) => setState(() {
                    _catKey = v;
                    _tab = null;
                    _pickDefaults();
                  }),
                )
              else if (cats.length > 2)
                _CategoryRow(label: cat == null ? '' : categoryLabel(cat), onTap: _pickCategory),
              if (cats.length >= 2) const SizedBox(height: 10),
              if (tabs.isNotEmpty)
                Segmented<String>(
                  items: tabs,
                  value: tab,
                  onChanged: (v) => setState(() => _tab = v),
                ),
              const SizedBox(height: 12),
              _StatusLine(text: view.status, tone: view.tone),
              if (view.rows.isNotEmpty) ...[
                const SizedBox(height: 10),
                Plate(
                  margin: EdgeInsets.zero,
                  child: Column(
                    children: [
                      for (var i = 0; i < view.rows.length; i++) ...[
                        if (i > 0) const Hairline(indent: 16),
                        _ResultRow(
                          row: view.rows[i],
                          panel: seg?.panel ?? const [],
                          ours: ours.contains(personKey(view.rows[i].name)),
                          total: tab == totalTab,
                          cols: tab == totalTab ? (cat?.total?.cols ?? const []) : const [],
                          open: _open.contains(_rowKey(tab, view.rows[i])),
                          onTap: _hasDetails(view.rows[i])
                              ? () => setState(() {
                                  final key = _rowKey(tab, view.rows[i]);
                                  _open.contains(key) ? _open.remove(key) : _open.add(key);
                                })
                              : null,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
              if (view.application && s.field.isNotEmpty) ...[
                const SizedBox(height: 10),
                Plate(
                  margin: EdgeInsets.zero,
                  child: Column(
                    children: [
                      for (var i = 0; i < s.field.length; i++) ...[
                        if (i > 0) const Hairline(indent: 16),
                        _FieldRow(
                          name: s.field[i].name,
                          time: s.field[i].time,
                          ours: ours.contains(personKey(s.field[i].name)),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
              if (view.retry) ...[
                const SizedBox(height: 14),
                SheetButton(
                  neutral: true,
                  label: 'Повторить',
                  onTap: _busy ? null : _reload,
                ),
              ],
              if (seg != null && seg.panel.isNotEmpty) ...[
                const SizedBox(height: 14),
                PanelBlock(
                  panel: seg.panel,
                  open: _panelOpen,
                  onTap: () => setState(() => _panelOpen = !_panelOpen),
                ),
              ],
              if (seg != null && seg.judges != null) ...[
                const SizedBox(height: 14),
                SheetButton(
                  neutral: true,
                  icon: CupertinoIcons.doc_text,
                  label: 'Оценки судей',
                  onTap: () => _openOrig(seg.judges!),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Ключ раскрытой строки: вкладка, стартовый номер и имя — после обновления файла раскрыт тот же человек.
  static String _rowKey(String tab, ProtocolRow r) => '$tab/${r.no ?? ''}/${r.name}';

  /// Раскрывается строка, где есть судейские оценки или элементы.
  static bool _hasDetails(ProtocolRow r) =>
      r.tes != null ||
      r.pcs != null ||
      r.ded != null ||
      r.elements.isNotEmpty ||
      r.components.isNotEmpty ||
      r.deductions.isNotEmpty;
}

/// Статус под переключателем: точка и текст.
class _StatusLine extends StatelessWidget {
  final String text;
  final ProtocolTone tone;
  const _StatusLine({required this.text, required this.tone});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final color = switch (tone) {
      ProtocolTone.finalized => p.accent,
      ProtocolTone.live => p.live,
      ProtocolTone.quiet => p.ink2,
    };
    return Semantics(
      liveRegion: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, height: 1.3, color: color)),
          ),
        ],
      ),
    );
  }
}

/// Выбор категории, когда их больше двух: строка с текущей категорией и листом выбора.
class _CategoryRow extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _CategoryRow({required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Plate(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
          child: Row(
            children: [
              Expanded(
                child: Text(label, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: p.ink)),
              ),
              Icon(CupertinoIcons.chevron_down, size: 17, color: p.ink3),
            ],
          ),
        ),
      ),
    );
  }
}

/// Строка протокола: место, имя, страна, баллы. Раскрытие — судейские оценки и элементы.
class _ResultRow extends StatelessWidget {
  final ProtocolRow row;
  final bool ours, total, open;
  final List<String> cols;
  final List<ProtocolJudge> panel;
  final VoidCallback? onTap;
  const _ResultRow({
    required this.row,
    required this.panel,
    required this.ours,
    required this.total,
    required this.cols,
    required this.open,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final place = row.place;
    final lead = place != null
        ? SizedBox(
            width: 30,
            child: Center(
              child: place <= 3
                  ? Medal(place, size: 26)
                  : Text('$place', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: p.accent, fontFeatures: tnum)),
            ),
          )
        : SizedBox(
            width: 30,
            child: Text('—', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: p.ink2)),
          );
    final parts = row.parts;
    final status = place == null && row.status != null ? statusLabel(row.status!) : null;
    final sub = <String>[
      // слово статуса переносится вместе с остальным под имя, а не ужимается в узкую колонку
      ?status,
      if (row.nation.isNotEmpty) row.nation,
      if (parts != null)
        for (var i = 0; i < parts.length && i < cols.length; i++) '${colLabel(cols[i])} ${parts[i] ?? '—'}',
    ];
    final body = Container(
      decoration: ours ? BoxDecoration(color: p.frost, border: Border(left: BorderSide(color: p.accent, width: 3))) : null,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          lead,
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayName(row.name),
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, height: 1.25, color: p.ink),
                ),
                if (sub.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      sub.join(' · '),
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, color: p.ink2, height: 1.3),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            row.points ?? '—',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: p.ink, fontFeatures: tnum),
          ),
          if (onTap != null)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Icon(open ? CupertinoIcons.chevron_up : CupertinoIcons.chevron_down, size: 15, color: p.ink3),
            ),
        ],
      ),
    );
    return Semantics(
      button: onTap != null,
      expanded: onTap == null ? null : open,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(onTap: onTap, child: body),
          if (open) Details(row: row, panel: panel),
        ],
      ),
    );
  }
}

/// Состав по заявке: имя и время выхода — без мест и баллов.
class _FieldRow extends StatelessWidget {
  final String name;
  final String? time;
  final bool ours;
  const _FieldRow({required this.name, required this.time, required this.ours});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      decoration: ours ? BoxDecoration(color: p.frost, border: Border(left: BorderSide(color: p.accent, width: 3))) : null,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(displayName(name), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, height: 1.25, color: p.ink)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(time ?? '—', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: p.ink2, fontFeatures: tnum)),
        ],
      ),
    );
  }
}
