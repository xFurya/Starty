// Итоги прямо с табло турнира (Swiss Timing), пока старт идёт и сразу после него:
// приложение не ждёт сбора на сервере. Тот же разбор, что у сборщика (scraper/swisstiming.py):
// страница сегмента SEGnnn.htm после первых прокатов показывает протокол — места по ходу старта.
// Окончательность — не из оглавления табло, а из basis в events.json: его выставляет сборщик
// по судейским оценкам (см. docs протокола в ПРОЕКТ.md).
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'data.dart';
import 'protocol_model.dart';

class LiveRow {
  final int place;
  final String name, nation, points;
  final List<String> cells;
  final int? pi;
  LiveRow(this.place, this.name, this.nation, this.points, this.cells, this.pi);
}

/// Итог одного опроса табло. Пустой результат — не null: у каждого исхода своя обработка в state.dart.
sealed class LiveResult {
  const LiveResult();
}

/// Табло ответило, прокаты есть: итоги для карточки старта.
final class LiveOk extends LiveResult {
  final List<Placing> podium;
  final bool provisional;
  final Map<String, int> places;
  final List<Placing>? total;
  final Map<String, int> finals;

  /// Все строки сегмента (место, имя, страна, баллы), не только тройка.
  final List<Placing> rows;
  const LiveOk({
    required this.podium,
    required this.provisional,
    this.rows = const [],
    this.places = const {},
    this.total,
    this.finals = const {},
  });
}

/// Прокатов ещё нет (стартовый лист, пустая таблица) — прошлое состояние не меняем.
final class LiveNone extends LiveResult {
  const LiveNone();
}

/// Сеть, таймаут или ошибка сервера табло — прошлое состояние не меняем.
final class LiveNet extends LiveResult {
  const LiveNet();
}

/// Страница пришла, но таблиц в ней нет (чужая или сломанная страница) — не понижаем состояние.
final class LiveFormat extends LiveResult {
  const LiveFormat();
}

/// Исход чтения одной страницы табло.
enum LiveFetch { ok, none, net }

final _script = RegExp(r'<(script|style)[^>]*>.*?</\1>', dotAll: true, caseSensitive: false);
final _nested = RegExp(
  r'(<td[^>]*>)\s*<table[^>]*>\s*(?:<tbody[^>]*>\s*)?<tr[^>]*>((?:(?!<table\b|<tr\b|</tr>).)*)</tr>\s*(?:</tbody>\s*)?</table>\s*(</td>)',
  dotAll: true,
  caseSensitive: false,
);
final _tr = RegExp(r'<tr[^>]*>(.*?)</tr>', dotAll: true, caseSensitive: false);
final _td = RegExp(r'<t[dh][^>]*>(.*?)</t[dh]>', dotAll: true, caseSensitive: false);
final _tag = RegExp(r'<[^>]+>', dotAll: true);
final _cellTag = RegExp(r'</?t[dh]\b[^>]*>', caseSensitive: false);
final _caption = RegExp(r'<caption[^>]*>(.*?)</caption>', dotAll: true, caseSensitive: false);
final _clubBreak = RegExp(r'</a>\s*<br\s*/?>', caseSensitive: false);
final _table = RegExp(r'<table[\s>]', caseSensitive: false);
final _points = RegExp(r'^\d{1,3}\.\d{2}$');
final _nation = RegExp(r'^[A-ZА-ЯЁ]{2,4}\d?(?:\s*/\s*[A-ZА-ЯЁ]{2,4}\d?)?$');
final _digits = RegExp(r'^\d+$');

String _unescape(String s) => s
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) => String.fromCharCode(int.parse(m[1]!, radix: 16)))
    .replaceAllMapped(RegExp(r'&#(\d+);'), (m) => String.fromCharCode(int.parse(m[1]!)))
    .replaceAll(' ', ' ');

String _text(String s) => _unescape(s.replaceAll(_tag, ' ')).replaceAll(RegExp(r'\s+'), ' ').trim();

/// Текст ячейки. «<a>Имя Фамилия</a><br/>Клуб» — только имя: клуб в той же ячейке (swisstiming.py, _cell_text).
String _cellText(String raw) {
  final m = _clubBreak.firstMatch(raw);
  return _text(m == null ? raw : '${raw.substring(0, m.start)}</a>');
}

/// Старшая половина cp1251 (0x80–0xBF); 0xC0–0xFF — «А»–«я» подряд, с U+0410.
const _cp1251Upper =
    '\u0402\u0403\u201a\u0453\u201e\u2026\u2020\u2021\u20ac\u2030\u0409\u2039\u040a\u040c\u040b\u040f'
    '\u0452\u2018\u2019\u201c\u201d\u2022\u2013\u2014\ufffd\u2122\u0459\u203a\u045a\u045c\u045b\u045f'
    '\u00a0\u040e\u045e\u0408\u00a4\u0490\u00a6\u00a7\u0401\u00a9\u0404\u00ab\u00ac\u00ad\u00ae\u0407'
    '\u00b0\u00b1\u0406\u0456\u0491\u00b5\u00b6\u00b7\u0451\u2116\u0454\u00bb\u0458\u0405\u0455\u0457';

/// Страница табло: сначала UTF-8, иначе cp1251 — ФФКМ отдаёт cp1251 без заголовка кодировки
/// (как scraper/net.py, _decode). Таблица cp1251 полная: не декодируется только 0x98.
String decodeTablo(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    final units = [for (final b in bytes) b < 0x80 ? b : (b < 0xC0 ? _cp1251Upper.codeUnitAt(b - 0x80) : 0x410 + b - 0xC0)];
    return String.fromCharCodes(units);
  }
}

/// Строки таблиц страницы: ячейки текстом. Флаг страны лежит во вложенной табличке — сворачиваем её.
/// Подпись таблицы (<caption>) становится строкой, как в swisstiming.py.
List<List<String>> _rows(String page) {
  page = page.replaceAll(_script, '');
  page = page.replaceAllMapped(_caption, (m) => '<tr><td>${m[1]}</td></tr>');
  page = page.replaceAllMapped(_nested, (m) => '${m[1]}${m[2]!.replaceAll(_cellTag, ' ')}${m[3]}');
  return [
    for (final r in _tr.allMatches(page)) [for (final c in _td.allMatches(r[1]!)) _cellText(c[1]!)],
  ];
}

const _resultHeads = {'Pl.', 'Pl', 'Мес.', 'Место', 'FPl.', 'FPl', 'Мест.', 'М.'};
const _nameHeads = {'Name', 'Имя', 'Спортсмен', 'Участник'};
const _nationHeads = {'Nation', 'Nat.', 'Регион', 'Страна', 'Нация'};

int? _col(List<String> header, Set<String> names, {bool prefix = false}) {
  for (var i = 0; i < header.length; i++) {
    final h = header[i].trim();
    if (names.contains(h) || (prefix && names.any(h.startsWith))) return i;
  }
  return null;
}

LiveRow? _rowResult(List<String> cells, List<String> header, Set<String> pointsHeads) {
  final nonempty = cells.where((c) => c.isNotEmpty).toList();
  if (nonempty.length < 3 || !_digits.hasMatch(nonempty[0])) return null;
  final aligned = cells.length == header.length;
  final ni = aligned ? _col(header, _nameHeads) : null;
  final name = ni != null && cells[ni].isNotEmpty ? cells[ni] : nonempty[1];
  final after = cells.sublist(cells.indexOf(name) + 1);
  final pi = aligned ? _col(header, pointsHeads, prefix: true) : null;
  final points = pi != null && _points.hasMatch(cells[pi])
      ? cells[pi]
      : after.firstWhere(_points.hasMatch, orElse: () => '');
  if (points.isEmpty) return null;
  final ci = aligned ? _col(header, _nationHeads) : null;
  String nation;
  if (ci != null && _nation.hasMatch(cells[ci])) {
    nation = cells[ci];
  } else {
    final idx = after.indexOf(points);
    final before = idx >= 0 ? after.sublist(0, idx) : after;
    nation = before.firstWhere(_nation.hasMatch, orElse: () => '');
  }
  return LiveRow(int.parse(nonempty[0]), name, nation.replaceAll(' ', ''), points, cells, pi);
}

/// Таблица самого сегмента — с оценками за элементы и компоненты (TES, PCS).
bool _hasComponents(List<String> header) => header.any((h) => h.trim().startsWith('TES') || h.trim().startsWith('PCS'));

/// Таблица протокола: (шапка, строки по местам); null — страница ещё стартовый лист.
///
/// Во время старта на странице бывает несколько таблиц с одной шапкой «Pl.»: сам сегмент
/// и общий зачёт (короткая + произвольная). Берётся одна: у сегмента ([segment]) — с TES/PCS,
/// у итога — без них; если такой нет — первая. Один человек в таблице — один раз.
(List<String>, List<LiveRow>)? _resultTable(String page, Set<String> pointsHeads, {required bool segment}) {
  final tables = <(List<String>, List<LiveRow>)>[];
  for (final cells in _rows(page)) {
    final first = cells.firstWhere((c) => c.isNotEmpty, orElse: () => '');
    if (_resultHeads.contains(first) && _col(cells, _nameHeads) != null) {
      tables.add((cells, <LiveRow>[]));
      continue;
    }
    if (tables.isEmpty) continue;
    final row = _rowResult(cells, tables.last.$1, pointsHeads);
    if (row != null) tables.last.$2.add(row);
  }
  if (tables.isEmpty) return null;
  final pick = tables.where((t) => t.$2.isNotEmpty && _hasComponents(t.$1) == segment).firstOrNull ??
      tables.where((t) => t.$2.isNotEmpty).firstOrNull ??
      tables.first;
  // одна строка на пару «место + имя»: однофамильцы на разных местах не схлопываются
  final seen = <String>{};
  final rows = [
    for (final r in pick.$2)
      if (seen.add('${r.place}|${r.name}')) r,
  ]..sort((a, b) => a.place.compareTo(b.place));
  return (pick.$1, rows);
}

/// Протокол сегмента по местам; null — прокатов ещё не было.
List<LiveRow>? segmentResults(String page) =>
    _resultTable(page, {'TSS', 'Сумма', 'Points', 'Баллы'}, segment: true)?.$2;

/// Итог вида и полон ли он (у первой тройки места во всех сегментах).
(List<LiveRow>, bool) categoryResults(String page) {
  final t = _resultTable(page, {'Points', 'Баллы', 'Сумма', 'Total', 'TSS'}, segment: false);
  if (t == null || t.$2.isEmpty) return (const <LiveRow>[], false);
  final (header, rows) = t;
  for (final r in rows.take(3)) {
    final pi = r.pi;
    if (pi == null) return (rows, false);
    final segCols = [for (var j = pi + 1; j < header.length; j++) if (header[j].isNotEmpty) j];
    if (segCols.isEmpty || !segCols.every((j) => j < r.cells.length && r.cells[j].isNotEmpty)) return (rows, false);
  }
  return (rows, true);
}

/// «Vladislav DIKIDZHI» → «Vladislav Dikidzhi», «Даниил ЖОЛОБОВ» → «Даниил Жолобов»: фамилии капсом
/// табло приводятся к обычному написанию, если сборщик не передал готовое имя.
String titledName(String name) => name.replaceAllMapped(
  RegExp(r"(?<![\p{L}])(\p{Lu})([\p{Lu}'\-]+)(?![\p{L}])", unicode: true),
  (m) => '${m[1]}${m[2]!.toLowerCase().replaceAllMapped(RegExp(r"-(\p{L})", unicode: true), (h) => "-${h[1]!.toUpperCase()}")}',
);

/// Ключ человека для сопоставления имён файла протокола и расписания: первое и последнее слово,
/// без регистра и «ё». «Анна Павловна БИЛИБИНА» и «Анна Билибина» дают один ключ.
String personKey(String name) => name
    .split(' / ')
    .map((m) {
      final w = m.trim().toLowerCase().replaceAll('ё', 'е').split(RegExp(r'\s+')).where((x) => x.isNotEmpty).toList();
      return w.isEmpty ? '' : (w.length == 1 ? w.first : '${w.first} ${w.last}');
    })
    .join(' / ');

/// Итоги старта из файла протокола (режим «с опозданием»): то же, что дал бы опрос табло.
/// Имена берём как в расписании (events.json), если человек там есть; иначе — как в файле.
LiveResult liveFromProtocol(Start s, ProtocolDoc doc) {
  final cat = doc.categoryFor(s.kind, s.level);
  final seg = cat?.segmentOf(s.seg);
  if (seg == null || seg.rows.isEmpty) return const LiveNone();
  // сверка не сошлась или файл не распознан — итогов не показываем
  if (seg.state == SegmentState.format || seg.state == SegmentState.judgesMismatch) return const LiveFormat();
  final byKey = {for (final f in s.field) personKey(f.name): f.name};
  String displayOf(String name) => byKey[personKey(name)] ?? name;
  final rows = [for (final r in seg.rows) if (r.place != null) r]..sort((a, b) => a.place!.compareTo(b.place!));
  if (rows.isEmpty) return const LiveNone();
  // окончательность — только судейские оценки (проверено при разборе файла)
  final done = seg.state == SegmentState.finalized;
  final podium = [
    for (final r in rows.take(3)) Placing(r.place!, displayOf(r.name), r.nation, r.points ?? ''),
  ];
  final places = {for (final r in rows) norm(displayOf(r.name)): r.place!};
  List<Placing>? total;
  var finals = const <String, int>{};
  final t = cat!.total;
  if (done && t != null && t.state == TotalState.finalized && t.complete && s.total.isEmpty) {
    final trows = [for (final r in t.rows) if (r.place != null) r]..sort((a, b) => a.place!.compareTo(b.place!));
    if (trows.isNotEmpty) {
      total = [for (final r in trows.take(3)) Placing(r.place!, displayOf(r.name), r.nation, r.points ?? '')];
      finals = {for (final r in trows) norm(displayOf(r.name)): r.place!};
    }
  }
  final all = [for (final r in rows) Placing(r.place!, displayOf(r.name), r.nation, r.points ?? '')];
  return LiveOk(podium: podium, provisional: !done, rows: all, places: places, total: total, finals: finals);
}

class Live {
  /// Клиент — подменяется в тестах (MockClient).
  static http.Client client = http.Client();

  /// Страница табло: 200 — текст, 404/410 — страницы нет, остальное (сеть, таймаут, 5xx) — net.
  static Future<(LiveFetch, String?)> _get(String url) async {
    try {
      final r = await client
          .get(Uri.parse(url), headers: {'Cache-Control': 'no-cache'})
          .timeout(const Duration(seconds: 15));
      if (r.statusCode == 404 || r.statusCode == 410) return (LiveFetch.none, null);
      if (r.statusCode != 200) return (LiveFetch.net, null);
      return (LiveFetch.ok, decodeTablo(r.bodyBytes));
    } catch (_) {
      return (LiveFetch.net, null);
    }
  }

  /// Свежие итоги старта с табло. Окончательность — по basis из events.json (судейские оценки).
  static Future<LiveResult> poll(Start s) async {
    final src = s.live;
    if (src == null || src.seg.isEmpty) return const LiveNone();
    final (kind, page) = await _get(src.seg);
    if (kind == LiveFetch.net) return const LiveNet();
    if (kind == LiveFetch.none || page == null) return const LiveNone();
    if (!_table.hasMatch(page)) return const LiveFormat();
    final rows = segmentResults(page);
    if (rows == null || rows.isEmpty) return const LiveNone();
    // судейские оценки (или время, если сборщик включил такой режим) — окончательно
    final basis = src.basis;
    final done = basis == 'judges' || basis == 'time';
    String ru(String latin) => src.names[latin] ?? titledName(latin);
    final podium = [for (final r in rows.take(3)) Placing(r.place, ru(r.name), r.nation, r.points)];
    final places = {for (final r in rows) norm(ru(r.name)): r.place};
    List<Placing>? total;
    var finals = const <String, int>{};
    if (done && src.cat != null && s.total.isEmpty) {
      // итог вида — только при окончательном сегменте; сбой итога не понижает ничего
      final (catKind, cat) = await _get(src.cat!);
      if (catKind == LiveFetch.ok && cat != null) {
        final (all, complete) = categoryResults(cat);
        if (complete) {
          total = [for (final r in all.take(3)) Placing(r.place, ru(r.name), r.nation, r.points)];
          finals = {for (final r in all) norm(ru(r.name)): r.place};
        }
      }
    }
    final all = [for (final r in rows) Placing(r.place, ru(r.name), r.nation, r.points)];
    return LiveOk(podium: podium, provisional: !done, rows: all, places: places, total: total, finals: finals);
  }
}
