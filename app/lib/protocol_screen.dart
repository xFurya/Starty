import 'dart:async';
// Протокол турнира в приложении: категория → сегмент (короткая, произвольная, итог) → строки.
// Данные — из файла протокола (protocol_model.dart); оригинал табло — значком в верхней панели, во встроенном браузере.
// Честность: число показываем только если оно есть в файле, окончательность — только по судейским оценкам.
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

import 'data.dart';
import 'flags.dart';
import 'profile.dart' show KindScope;
import 'live.dart' show LiveOk, personKey;
import 'needs.dart';
import 'pace.dart';
import 'palette.dart';
import 'platform.dart';
import 'protocol_model.dart';
import 'protocol_details.dart';
import 'protocol.dart' show openOriginal;
import 'protocol_repo.dart';
import 'state.dart' show AppState;
import 'ui.dart';
import 'views.dart' show LivePill;

/// Подписи вкладок сегментов: короткие, чтобы три вкладки умещались в ширину 360 px.
const _tabLabel = {'КП': 'Короткая', 'ПП': 'Произвольная', 'РТ': 'Ритм-танец', 'ПТ': 'Произвольный'};
const totalTab = 'итог';

/// Цвет строки статуса: окончательный — акцент, идущий — цвет живого, остальное — приглушённый.
enum ProtocolTone { finalized, live, quiet }

/// Что показать под переключателем: текст статуса, список и кнопку «Повторить».
class ProtocolView {
  /// Состояние словами; у идущего сегмента может быть пустым — его показывает метка «Идёт».
  final String status;
  final ProtocolTone tone;
  final bool retry;

  /// Сколько выступило: «Выступили 9 из 14» — строкой под состоянием.
  final String progress;

  /// Когда обновлён или сохранён файл — справа от состояния, тихо.
  final String note;

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
    this.progress = '',
    this.note = '',
  });
}

/// «Выступили 9 из 14» — только если известен весь состав.
String _progress(int done, int field) => field >= done && done > 0 ? 'Выступили $done из $field' : '';

/// Текст статуса по загрузке файла, категории и вкладке. Все тексты — из утверждённых макетов.
/// [category] — категория из файла (той же загрузки, что и [load], или из кэша); null — её нет.
ProtocolView protocolView(
  ProtocolLoad load, {
  required ProtocolCategory? category,
  required String tab,
  required bool hasField,
  DateTime? built,
  int fieldCount = 0,
  DateTime? stamp,
}) {
  // Любой сбой при наличии сохранённого файла — сохранённая версия; без него — короткий текст
  // (экран в этом случае не открывается, сразу открывается оригинал, см. [ProtocolScreen]).
  final (cached, cachedAt) = savedOf(load);
  if (cached != null && cachedAt != null) {
    final v = _inFile(category, tab, hasField: hasField, built: cached.built, fieldCount: fieldCount, stamp: stamp);
    // сохранённая версия: о сбоях не рассказываем — только от какого времени то, что на экране
    return ProtocolView(
      v.status,
      v.tone,
      retry: true,
      rows: v.rows,
      application: v.application,
      noFile: v.noFile,
      progress: v.progress,
      note: v.note.isNotEmpty || v.tone == ProtocolTone.finalized ? v.note : 'сохранено ${_dm(cachedAt)}, ${hm(cachedAt)}',
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
      return _inFile(category, tab, hasField: hasField, built: built, fieldCount: fieldCount, stamp: stamp);
  }
}

/// Сохранённая версия файла и время её сохранения при любом сбое загрузки; (null, null) — её нет или загрузка удалась.
(ProtocolDoc?, DateTime?) savedOf(ProtocolLoad load) => switch (load) {
  ProtocolNetError(:final cached, :final cachedAt) => (cached, cachedAt),
  ProtocolMissing(:final cached, :final cachedAt) => (cached, cachedAt),
  ProtocolFormatError(:final cached, :final cachedAt) => (cached, cachedAt),
  ProtocolOk() => (null, null),
};

/// Отпечаток того, что протокол показывает: состояния сегментов и итога, строки, баллы, элементы и
/// судьи. Время сборки не входит — оно новое при каждом чтении табло, даже когда нового нет.
String protocolSig(ProtocolDoc? d) {
  if (d == null) return '';
  String row(ProtocolRow r) =>
      '${r.place}/${r.status}/${r.name}/${r.points}/${r.tes}/${r.pcs}/${r.ded}/${r.elements.length}/${r.components.length}/${r.parts?.join('|')}';
  final b = StringBuffer();
  for (final c in d.categories) {
    b.write('${c.kind}|${c.level}[');
    for (final s in c.segments) {
      b.write('${s.code}:${s.state.wire}:${s.basis}:${s.skipped}:${s.panel.length}:${s.judges}(');
      b.writeAll(s.rows.map(row), ',');
      b.write(')');
    }
    final t = c.total;
    if (t != null) {
      b.write('T:${t.state.wire}:${t.skipped}(');
      b.writeAll(t.rows.map(row), ',');
      b.write(')');
    }
    b.write(']');
  }
  return b.toString();
}

ProtocolView _noProtocol(bool hasField) => hasField
    ? const ProtocolView('Протокола пока нет', ProtocolTone.quiet, application: true, noFile: true)
    : const ProtocolView('Протокола и заявки пока нет', ProtocolTone.quiet, noFile: true);

ProtocolView _inFile(ProtocolCategory? category, String tab, {required bool hasField, DateTime? built, int fieldCount = 0, DateTime? stamp}) {
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
    return ProtocolView(asOf(stamp, built), ProtocolTone.quiet, rows: t.rows);
  }
  final seg = category.segmentOf(tab);
  if (seg == null) return _noProtocol(hasField);
  switch (seg.state) {
    case SegmentState.scheduled:
    case SegmentState.notPublished:
      return _noProtocol(hasField);
    case SegmentState.inProgress:
      // оценок ещё нет, а табло уже пишет, кто выходит: сегмент идёт — метка «Идёт» и стартовый порядок
      if (seg.rows.isEmpty && seg.next != null && hasField) {
        return ProtocolView('', ProtocolTone.live, application: true, noFile: true, note: asOf(stamp, built));
      }
      if (seg.rows.isEmpty) return _noProtocol(hasField);
      // «Идёт» — меткой; сколько выступило — строкой ниже; когда обновлено — справа
      return ProtocolView(
        '',
        ProtocolTone.live,
        rows: seg.rows,
        // снявшиеся (строка со статусом, без места) — не «выступили»
        progress: _progress(seg.rows.where((r) => r.place != null).length, fieldCount),
        note: asOf(stamp, built),
      );
    case SegmentState.provisional:
      if (seg.rows.isEmpty) return _noProtocol(hasField);
      return ProtocolView(asOf(stamp, built), ProtocolTone.quiet, rows: seg.rows);
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

/// Почему у строки сегмента есть итоги, а разбора по элементам нет. Элементы и оценки судей берутся
/// только из опубликованного судейского протокола: пока его нет (сегмент идёт или итоги
/// предварительные) — он появится; в окончательном — для этого участника его в файле нет.
/// У «Итога» вида ([state] == null) разбора не бывает — молчим.
String? missingDetails(SegmentState? state) => switch (state) {
  SegmentState.inProgress || SegmentState.provisional => 'Элементы и оценки судей появятся, когда их опубликуют',
  SegmentState.finalized => 'Элементов и оценок судей в протоколе нет',
  _ => null,
};

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

/// Строки протокола: со статусом и без места (дисквалифицирован, снят) — после всех с местами. Табло
/// ISU ставит дисквалифицированного первым (на его прежнее место), а место у него больше никакое.
List<ProtocolRow> statusLast(List<ProtocolRow> rows) => [
  for (final r in rows)
    if (r.place != null || r.status == null) r,
  for (final r in rows)
    if (r.place == null && r.status != null) r,
];

/// Статус участника без места по-русски; незнакомый остаётся как в файле.
String statusLabel(String s) {
  const m = {
    'WD': 'снят',
    'DNS': 'не вышел',
    'DQ': 'дисквалифицирован',
    'DSQ': 'дисквалифицирован',
    'RET': 'прервал',
    'NQ': 'не допущен',
    'NQD': 'не прошёл',
    'UNR': 'без места',
    'NP': 'без места',
  };
  return m[s.trim().toUpperCase()] ?? s;
}

/// От какого времени то, что на экране: «Табло от 14:52» — время самого табло (страница сегмента
/// обновилась тогда), другой день — с датой. Табло своего времени не пишет — когда собран файл.
/// Почему не свежее (сеть, табло молчит) — не рассказываем: человеку важно, от какого момента данные.
String asOf(DateTime? stamp, DateTime? built) {
  String when(DateTime t) => dayKey(t) == dayKey(now()) ? hm(t) : '${_dm(t)}, ${hm(t)}';
  if (stamp != null) return 'Табло от ${when(stamp)}';
  return built == null ? '' : 'Обновлено ${when(built)}';
}

String _dm(DateTime t) {
  final m = msk(t);
  return '${two(m.day)}.${two(m.month)}';
}

/// Подпись категории для переключателя — одним названием: «Женщины», «Девушки»,
/// «Юниорские пары»; незнакомый уровень — в скобках.
/// Ключ категории для выбора: вид, уровень и командный ли турнир (у командного те же вид и уровень).
String categoryKey(ProtocolCategory c) => '${c.kind}|${c.level}${c.team ? '|team' : ''}';

String categoryLabel(ProtocolCategory c) {
  if (c.team) return 'Командный, ${(kindNames[c.kind] ?? c.kind).toLowerCase()}';
  final kind = kindNames[c.kind] ?? c.kind;
  if (c.level == 'senior') return kind;
  if (c.level == 'junior') {
    return {'women': 'Девушки', 'men': 'Юноши', 'pairs': 'Юниорские пары', 'dance': 'Юниорские танцы'}[c.kind] ?? '$kind (юниоры)';
  }
  return c.level.isEmpty ? kind : '$kind (${levelNames[c.level]?.toLowerCase() ?? c.level})';
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

  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _reload();
    _schedule();
  }

  /// Пока что-то в протоколе не окончательное — обновляем сами: «моментально» — с частотой старта
  /// (настройки или старт) прямо с табло, иначе — раз в пять минут из файла. Срок читается каждый раз
  /// заново: смена частоты действует сразу.
  void _schedule() {
    _timer?.cancel();
    final every = _instant ? Duration(seconds: widget.state!.liveEveryOf(widget.start)) : const Duration(minutes: 5);
    _timer = Timer(every, () async {
      if (!mounted) return;
      if (!_busy && !_everyFinal) await _reload(auto: true);
      if (mounted) _schedule();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  bool get _instant {
    final st = widget.state;
    return st != null && st.liveModeOf(widget.start) == liveInstant;
  }

  /// Всё в файле окончательное: обновлять нечего. Сегмент «по расписанию» окончательным не
  /// считается, если он начнётся в ближайшие два часа или его время уже пришло: раньше экран,
  /// открытый до начала, так и не обновлялся сам — протокол появлялся только по кнопке.
  bool get _everyFinal {
    final d = _doc;
    if (d == null) return false;
    final soon = now().add(const Duration(hours: 2));
    bool quiet(ProtocolSegment x) =>
        x.state == SegmentState.finalized || (x.state == SegmentState.scheduled && x.start != null && x.start!.isAfter(soon));
    return d.categories.every((c) => c.segments.every(quiet) && (c.total == null || c.total!.state == TotalState.finalized));
  }

  /// [manual] — нажата кнопка обновления: протокол собирается на устройстве с табло в любом режиме,
  /// заодно обновляется расписание (до старта новое — в составе и времени, а не в протоколе),
  /// и внизу коротко сказано, что вышло.
  Future<void> _reload({bool manual = false, bool auto = false}) async {
    final proto = widget.start.proto;
    if (!auto) setState(() => _busy = true);
    // состав сверяем у той же вкладки: переключение во время обновления — не «состав обновлён»
    final cat = _category, tab = _tab ?? totalTab;
    final docBefore = protocolSig(_doc), fieldBefore = _fieldSig(cat, tab);
    final schedule = manual ? widget.state?.load() : null;
    // в браузере табло недоступно: только файл сайта, без ложного «табло не ответило»
    final device = canReadBoards && widget.state != null && (manual || _instant);
    final load = proto == null
        ? const ProtocolMissing()
        : await _repo.load(proto, start: widget.start, starts: widget.state?.data?.starts ?? const [], device: device);
    try {
      await schedule;
    } catch (_) {}
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
    // собрано с табло на устройстве: кто уже выступил — в темп (время выхода оставшихся)
    if (device && load is ProtocolOk) widget.state?.noteProtocol(_siblings, load.doc);
    if (manual) _tell(load, docBefore, fieldBefore == _fieldSig(cat, tab));
  }

  /// Состав вкладки по заявке: номера, время, места.
  String _fieldSig(ProtocolCategory? cat, String tab) => [
    for (final x in _startOf(cat, tab)?.field ?? const <Skater>[])
      '${x.name}/${x.no}/${x.time}/${x.place}/${x.points}',
  ].join(',');

  /// Итог ручного обновления: без него нажатие до старта и после окончательных итогов выглядит пустым.
  /// Почему не обновилось, не рассказываем — только что вышло и от какого времени табло.
  void _tell(ProtocolLoad load, String docBefore, bool sameField) {
    final tab = _tab ?? totalTab;
    final stamp = tab == totalTab ? _category?.total?.stamp : _category?.segmentOf(tab)?.stamp;
    final at = asOf(stamp, null);
    final text = protocolSig(_doc) != docBefore
        ? 'Протокол обновлён'
        : !sameField
            ? 'Состав обновлён'
            : (at.isEmpty ? 'Нового нет' : 'Нового нет. $at');
    final p = Palette.of(context);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text, style: TextStyle(fontFamily: sans, fontSize: 14.5, color: p.bg, height: 1.3)),
          behavior: SnackBarBehavior.floating,
          backgroundColor: p.ink,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          duration: const Duration(seconds: 2),
        ),
      );
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
      if (categoryKey(c) == _catKey) return c;
    }
    return null;
  }

  /// Старты этого турнира из расписания, открытый — первым.
  Iterable<Start> get _siblings sync* {
    final s = widget.start;
    yield s;
    for (final x in widget.state?.data?.starts ?? const <Start>[]) {
      if (x.tid == s.tid && x.id != s.id) yield x;
    }
  }

  /// Старт выбранной категории и вкладки: состав по заявке, «выступили N из M» и табло — его, а не
  /// того, с которого открыт экран. Файла нет (выбирать не из чего) — старт экрана; такого старта
  /// в расписании нет — null, и заявки у вкладки нет.
  Start? _startOf(ProtocolCategory? cat, String tab) {
    if (cat == null) return widget.start;
    for (final x in _siblings) {
      if (x.kind == cat.kind && x.level == cat.level && x.seg == tab) return x;
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
      final match = _doc?.categoryFor(s.kind, s.level, team: s.team) ?? cats.first;
      _catKey = categoryKey(match);
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
                  on: categoryKey(cat) == _catKey,
                  onTap: () => Navigator.of(c).pop(categoryKey(cat)),
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
    // имя в протоколе открывает того, кто выступал в этом виде (тёзки — см. KindScope)
    if (state == null) return KindScope(kind: widget.start.kind, child: Builder(builder: _build));
    return KindScope(
      kind: widget.start.kind,
      child: ListenableBuilder(listenable: state, builder: (c, _) => _build(c)),
    );
  }

  Widget _build(BuildContext context) {
    final s = widget.start;
    final doc = _doc;
    final cat = _category;
    final tab = _tab ?? totalTab;
    final seg = tab == totalTab ? null : cat?.segmentOf(tab);
    // заявка выбранной категории и вкладки; у «Итога» и у вкладки без старта в расписании её нет
    final here = _startOf(cat, tab);
    final field = here?.field ?? const <Skater>[];
    final live = here == null ? null : widget.state?.liveOf(here.id);
    final load = _load;
    final stamp = tab == totalTab ? cat?.total?.stamp : seg?.stamp;
    var view = load == null
        ? const ProtocolView('Загружаем протокол…', ProtocolTone.quiet)
        : protocolView(load, category: cat, tab: tab, hasField: field.isNotEmpty, built: doc?.built, fieldCount: field.length, stamp: stamp);
    // В файле строк нет, а табло уже показало итоги этого старта — показываем их, пока файл не обновится.
    final onBoard = live != null && live.rows.isNotEmpty && view.noFile;
    if (onBoard) {
      view = ProtocolView(
        '',
        live.provisional ? ProtocolTone.live : ProtocolTone.quiet,
        progress: _progress(live.rows.length, field.length),
        note: asOf(live.stamp, null),
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
    // отслеживаемые всего турнира: в другой категории выделяются её люди
    final ours = {for (final x in _siblings) for (final o in x.ours) personKey(o.name)};
    final needs = _needsHere(cat, tab, view, here, onBoard ? live : null, ours);
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
            // пока идёт обновление — круг вместо значка: нажатие видно сразу
            icon: _busy
                ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Palette.of(context).accent))
                : const Icon(Icons.refresh),
            onPressed: _busy ? null : () => _reload(manual: true),
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
                  items: [for (final c in cats) (categoryKey(c), categoryLabel(c))],
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
              _StatusLine(text: view.status, tone: view.tone, progress: view.progress, note: view.note),
              if (needs.isNotEmpty && cat != null) _Needs(needs: needs, first: cat.segments.first.code, second: tab),
              if (view.rows.isNotEmpty) ...[
                const SizedBox(height: 10),
                Plate(
                  margin: EdgeInsets.zero,
                  child: Column(
                    children: [
                      for (final (i, row) in statusLast(view.rows).indexed) ...[
                        if (i > 0) const Hairline(indent: 16),
                        _ResultRow(
                          row: row,
                          panel: seg?.panel ?? const [],
                          missing: onBoard ? null : missingDetails(seg?.state),
                          ours: ours.contains(personKey(row.name)),
                          total: tab == totalTab,
                          cols: tab == totalTab ? (cat?.total?.cols ?? const []) : const [],
                          open: _open.contains(_rowKey(tab, row)),
                          onTap: _hasDetails(row)
                              ? () => setState(() {
                                  final key = _rowKey(tab, row);
                                  _open.contains(key) ? _open.remove(key) : _open.add(key);
                                })
                              : null,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
              // кто ещё выступит — по стартовому порядку, со временем выхода (с поправкой на темп);
              // до начала — весь стартовый порядок, по ходу — после выступивших
              if (here != null && tab != totalTab && (view.application || (view.rows.isNotEmpty && seg?.state != SegmentState.finalized)))
                ...() {
                  final left = waitingOf(here, view.rows);
                  if (left.isEmpty) return const <Widget>[];
                  return [
                    // порядок известен (номера или время выхода) — стартовый порядок; иначе — просто заявка
                    Eyebrow(
                      view.rows.isNotEmpty
                          ? 'Ещё выступят'
                          : (left.any((o) => o.no != null || o.time != null) ? 'Стартовый порядок' : 'Состав по заявке'),
                      padding: const EdgeInsets.fromLTRB(6, 18, 6, 8),
                    ),
                    if (paceLine(here.pace) case final line?)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
                        child: Text(line, style: TextStyle(fontSize: 13, height: 1.35, color: Palette.of(context).ink2)),
                      ),
                    Plate(
                      margin: EdgeInsets.zero,
                      child: Column(
                        children: [
                          for (var i = 0; i < left.length; i++) ...[
                            if (i > 0 && left[i].warmup != null && left[i].warmup != left[i - 1].warmup)
                              _WarmupHead(left[i].warmup!)
                            else if (i == 0 && left.any((x) => x.warmup != null) && left.first.warmup != null)
                              _WarmupHead(left.first.warmup!, first: true)
                            else if (i > 0)
                              const Hairline(indent: 16),
                            _FieldRow(
                              name: left[i].name,
                              nation: left[i].nation,
                              time: timeLabel(here, left[i]),
                              live: isNext(here, left[i]),
                              ours: ours.contains(personKey(left[i].name)),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ];
                }(),
              if (view.retry) ...[
                const SizedBox(height: 14),
                SheetButton(
                  neutral: true,
                  label: 'Повторить',
                  onTap: _busy ? null : () => _reload(manual: true),
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
            ],
          ),
        ),
      ),
    );
  }

  /// «Сколько нужно» (подписка): на вкладке второго сегмента вида, пока он не закончен.
  /// [board] — итоги с табло, когда на экране они, а не файл.
  List<Need> _needsHere(ProtocolCategory? cat, String tab, ProtocolView view, Start? here, LiveOk? board, Set<String> ours) {
    final st = widget.state;
    if (cat == null || st == null || ours.isEmpty || !st.billing.perksAt(now())) return const [];
    if (cat.segments.length != 2 || cat.segments.last.code != tab) return const [];
    final second = cat.segments.last;
    // второй сегмент закончен — порогов нет, всё уже в протоколе
    final over = board != null
        ? !board.provisional
        : const {SegmentState.provisional, SegmentState.finalized, SegmentState.judgesMismatch, SegmentState.format}.contains(second.state);
    if (over) return const [];
    return needsOf(
      first: cat.segments.first,
      // строки файла (в том числе стартовый лист без баллов) и, пока файла нет, — табло
      second: [...second.rows, if (board != null) ...view.rows],
      lineup: {for (final f in here?.field ?? const <Skater>[]) personKey(f.name)},
      ours: ours,
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

/// Статус под переключателем: слева состояние (идущий — меткой «Идёт», остальное — точкой
/// цвета состояния и словом), справа тихо — когда обновлено; строкой ниже — сколько выступило.
class _StatusLine extends StatelessWidget {
  final String text;
  final ProtocolTone tone;
  final String progress;
  final String note;
  const _StatusLine({required this.text, required this.tone, this.progress = '', this.note = ''});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final color = switch (tone) {
      ProtocolTone.finalized => p.accent,
      ProtocolTone.live => p.live,
      ProtocolTone.quiet => p.ink2,
    };
    final live = tone == ProtocolTone.live;
    final spoken = [if (live) 'Идёт', if (text.isNotEmpty) text, if (progress.isNotEmpty) progress, if (note.isNotEmpty) note];
    return Semantics(
      liveRegion: true,
      label: spoken.join(', '),
      child: ExcludeSemantics(
        child: MeasuredLayout(
          builder: (context, c) {
            final textStyle = TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, height: 1.3, color: color);
            final noteStyle = TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, height: 1.3, color: p.ink2, fontFeatures: tnum);
            // время справа помещается рядом с состоянием — в одну строку; нет — строкой ниже
            final marker = live ? textWidth(context, 'ИДЁТ', const TextStyle(fontSize: 10.5, letterSpacing: 1.1)) + 30 : 16.0;
            final side = note.isNotEmpty &&
                marker + (text.isEmpty ? 0 : textWidth(context, text, textStyle)) + 12 + textWidth(context, note, noteStyle) <= c.maxWidth;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    if (live)
                      const LivePill()
                    else
                      Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
                    if (text.isNotEmpty) ...[
                      SizedBox(width: live ? 10 : 8),
                      Flexible(child: Text(text, style: textStyle)),
                    ],
                    if (side) ...[
                      const Spacer(),
                      const SizedBox(width: 12),
                      Text(note, style: noteStyle),
                    ],
                  ],
                ),
                if (note.isNotEmpty && !side)
                  Padding(padding: const EdgeInsets.only(top: 3), child: Text(note, style: noteStyle)),
                if (progress.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(progress, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, height: 1.3, color: p.ink, fontFeatures: tnum)),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// «за произвольную», «перед произвольным танцем», «после короткой» — сегмент в нужном падеже.
String _segAfter(String code) => switch (code) {
  'КП' => 'после короткой',
  'РТ' => 'после ритм-танца',
  _ => 'после первого сегмента',
};
String _segFor(String code) => switch (code) {
  'ПП' => 'за произвольную',
  'ПТ' => 'за произвольный танец',
  _ => 'за второй сегмент',
};
String _segBefore(String code) => switch (code) {
  'ПП' => 'Перед произвольной',
  'ПТ' => 'Перед произвольным танцем',
  _ => 'Перед вторым сегментом',
};

/// «Сколько нужно» (подписка): по каждому отслеживаемому — место после первого сегмента и что ему
/// нужно во втором при нынешних итогах; до второго сегмента — отставание от первого места.
class _Needs extends StatelessWidget {
  final List<Need> needs;
  final String first, second;
  const _Needs({required this.needs, required this.first, required this.second});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final during = needs.first.during;
    final label = TextStyle(fontSize: 14, fontWeight: FontWeight.w600, height: 1.3, color: p.ink2);
    final value = TextStyle(fontSize: 15, fontWeight: FontWeight.w800, height: 1.3, color: p.ink, fontFeatures: tnum);
    Widget line(String l, String v) => Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Expanded(child: Text(l, style: label)),
          const SizedBox(width: 12),
          Text(v, style: value),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // заголовок не обрезается: без «за произвольную» непонятно, о каких баллах речь
        Eyebrow(
          during ? 'Сколько нужно ${_segFor(second)}' : _segBefore(second),
          maxLines: 2,
          padding: const EdgeInsets.fromLTRB(6, 16, 6, 8),
        ),
        Plate(
          margin: EdgeInsets.zero,
          child: Column(
            children: [
              for (var i = 0; i < needs.length; i++) ...[
                if (i > 0) const Hairline(indent: 16),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 13),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        protocolName(needs[i].name),
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, height: 1.25, color: p.ink),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          '${needs[i].place}-е место ${_segAfter(first)}, ${pointsText(needs[i].first)}',
                          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, height: 1.3, color: p.ink2, fontFeatures: tnum),
                        ),
                      ),
                      if (needs[i].win case final w?) line('Первое место', w.text),
                      if (needs[i].podium case final t?) line('Пьедестал', t.text),
                      if (!during && needs[i].behind != null) line('Отставание от первого места', pointsText(needs[i].behind!)),
                      if (!during && needs[i].ahead != null) line('Отрыв от второго места', pointsText(needs[i].ahead!)),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        if (during)
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 8, 6, 0),
            child: Text(
              'Считается по тем, кто уже откатал. С$nbкаждым новым прокатом может стать больше.',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, height: 1.35, color: p.ink2),
            ),
          ),
        const SizedBox(height: 4),
      ],
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

  /// Почему в раскрытой строке нет разбора по элементам (см. [missingDetails]).
  final String? missing;
  const _ResultRow({
    required this.row,
    required this.panel,
    this.missing,
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
    // под именем — каждое своим элементом: статус меткой, страна флагом с кодом,
    // места по сегментам — подписью сегмента и числом
    final small = TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: p.ink2, height: 1.3, fontFeatures: tnum);
    final sub = <Widget>[
      // слово статуса переносится вместе с остальным под имя, а не ужимается в узкую колонку
      if (status != null) Tag(status, strong: false),
      if (row.nation.isNotEmpty) NationTag(row.nation, style: small.copyWith(fontWeight: FontWeight.w700, letterSpacing: .6)),
      // у снятого/не вышедшего прочерки не нужны: только те сегменты, где место есть
      if (parts != null)
        for (var i = 0; i < parts.length && i < cols.length; i++)
          if (status == null || parts[i] != null)
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: '${colLabel(cols[i])}$nb', style: small.copyWith(color: p.ink3, fontWeight: FontWeight.w700)),
                  TextSpan(text: parts[i] ?? '—', style: small.copyWith(color: p.ink)),
                ],
              ),
              maxLines: 1,
              softWrap: false,
            ),
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
                  protocolName(row.name),
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, height: 1.25, color: p.ink),
                ),
                if (sub.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: sub,
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
          if (open) Details(row: row, panel: panel, missing: missing),
        ],
      ),
    );
  }
}

/// Состав по заявке: имя и время выхода — без мест и баллов.
/// Кто ещё выступит в сегменте [s]: по стартовому порядку (номерам), без тех, у кого в строках
/// протокола [done] уже место или статус, и без пропущенных — номер раньше последнего выступившего
/// (снялись). До начала — весь порядок.
List<Skater> waitingOf(Start s, List<ProtocolRow> done) {
  final order = [...s.field];
  if (order.every((o) => o.no != null)) order.sort((a, b) => a.no!.compareTo(b.no!));
  final gone = {for (final r in done) if (r.place != null || r.status != null) personKey(r.name)};
  final last = order.lastIndexWhere((o) => gone.contains(personKey(o.name)));
  return [for (var i = last + 1; i < order.length; i++) if (!gone.contains(personKey(order[i].name))) order[i]];
}

/// Выходит следующим или уже на льду (по оценке темпа).
bool isNext(Start s, Skater o) => s.pace?.next == personKey(o.name);

/// Время в строке стартового порядка: следующий, чьё время по оценке уже пришло, — «сейчас»;
/// поправленное по темпу — «≈15:22»; по расписанию — как есть; времени нет — номер.
String timeLabel(Start s, Skater o, {DateTime? t}) {
  final at = s.skateAt(o);
  if (isNext(s, o) && at != null && !at.isAfter(t ?? now())) return 'сейчас';
  if (o.time != null) return o.planned != null ? '≈${o.time}' : o.time!;
  return o.no != null ? '№$nb${o.no}' : '—';
}

/// Подпись разминки в стартовом порядке: «Разминка 2».
class _WarmupHead extends StatelessWidget {
  final int group;
  final bool first;
  const _WarmupHead(this.group, {this.first = false});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(16, first ? 10 : 12, 16, 6),
      decoration: first ? null : BoxDecoration(border: Border(top: BorderSide(color: p.line))),
      child: Text(
        'Разминка $group',
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: .4, color: p.ink2),
      ),
    );
  }
}

class _FieldRow extends StatelessWidget {
  final String name;
  final String nation;
  final String? time;
  final bool ours;

  /// Выходит следующим или уже на льду — время цветом живого.
  final bool live;
  const _FieldRow({required this.name, required this.time, required this.ours, this.nation = '', this.live = false});
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
                Text(protocolName(name), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, height: 1.25, color: p.ink)),
                if (nation.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: NationTag(
                      nation,
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, letterSpacing: .6, height: 1.3, color: p.ink2),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(time ?? '—', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: live ? p.live : p.ink2, fontFeatures: tnum)),
        ],
      ),
    );
  }
}
