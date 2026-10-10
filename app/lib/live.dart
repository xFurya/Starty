// Итоги прямо с табло турнира (Swiss Timing), пока старт идёт и сразу после него:
// приложение не ждёт сбора на сервере. Тот же разбор, что у сборщика (scraper/swisstiming.py):
// страница сегмента SEGnnn.htm после первых прокатов показывает протокол — места по ходу
// старта; окончательный он, когда в оглавлении у сегмента появились судейские оценки.
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'data.dart';

class LiveRow {
  final int place;
  final String name, nation, points;
  final List<String> cells;
  final int? pi;
  LiveRow(this.place, this.name, this.nation, this.points, this.cells, this.pi);
}

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

/// Строки таблиц страницы: ячейки текстом. Флаг страны лежит во вложенной табличке — сворачиваем её.
List<List<String>> _rows(String page) {
  page = page.replaceAll(_script, '');
  page = page.replaceAllMapped(_nested, (m) => '${m[1]}${m[2]!.replaceAll(_cellTag, ' ')}${m[3]}');
  return [
    for (final r in _tr.allMatches(page)) [for (final c in _td.allMatches(r[1]!)) _text(c[1]!)],
  ];
}

const _resultHeads = {'Pl.', 'Pl', 'Мес.', 'Место', 'FPl.', 'FPl', 'Мест.'};
const _nameHeads = {'Name', 'Имя', 'Спортсмен', 'Участник'};
const _nationHeads = {'Nation', 'Nat.', 'Регион', 'Страна', 'Нация'};

int? _col(List<String> header, Set<String> names, {bool prefix = false}) {
  for (var i = 0; i < header.length; i++) {
    final h = header[i].trim();
    if (names.contains(h) || (prefix && names.any(h.startsWith))) return i;
  }
  return null;
}

/// Таблица протокола: null — страница ещё стартовый лист.
List<LiveRow>? _resultRows(String page, Set<String> pointsHeads) {
  List<String>? header;
  final out = <LiveRow>[];
  for (final cells in _rows(page)) {
    if (header == null) {
      final first = cells.firstWhere((c) => c.isNotEmpty, orElse: () => '');
      if (_resultHeads.contains(first) && _col(cells, _nameHeads) != null) header = cells;
      continue;
    }
    final nonempty = cells.where((c) => c.isNotEmpty).toList();
    if (nonempty.length < 3 || !_digits.hasMatch(nonempty[0])) continue;
    final aligned = cells.length == header.length;
    final ni = aligned ? _col(header, _nameHeads) : null;
    final name = ni != null && cells[ni].isNotEmpty ? cells[ni] : nonempty[1];
    final after = cells.sublist(cells.indexOf(name) + 1);
    final pi = aligned ? _col(header, pointsHeads, prefix: true) : null;
    final points = pi != null && _points.hasMatch(cells[pi])
        ? cells[pi]
        : after.firstWhere(_points.hasMatch, orElse: () => '');
    if (points.isEmpty) continue;
    final ci = aligned ? _col(header, _nationHeads) : null;
    String nation;
    if (ci != null && _nation.hasMatch(cells[ci])) {
      nation = cells[ci];
    } else {
      final idx = after.indexOf(points);
      final before = idx >= 0 ? after.sublist(0, idx) : after;
      nation = before.firstWhere(_nation.hasMatch, orElse: () => '');
    }
    out.add(LiveRow(int.parse(nonempty[0]), name, nation.replaceAll(' ', ''), points, cells, pi));
  }
  if (header == null) return null;
  out.sort((a, b) => a.place.compareTo(b.place));
  return out;
}

/// Протокол сегмента по местам; null — прокатов ещё не было.
List<LiveRow>? segmentResults(String page) => _resultRows(page, {'TSS', 'Сумма', 'Points', 'Баллы'});

/// Итог вида и полон ли он (у первой тройки места во всех сегментах).
(List<LiveRow>, bool) categoryResults(String page) {
  List<String>? header;
  for (final cells in _rows(page)) {
    final first = cells.firstWhere((c) => c.isNotEmpty, orElse: () => '');
    if (_resultHeads.contains(first) && _col(cells, _nameHeads) != null) {
      header = cells;
      break;
    }
  }
  final rows = _resultRows(page, {'Points', 'Баллы', 'Сумма', 'Total', 'TSS'}) ?? const <LiveRow>[];
  if (header == null || rows.isEmpty) return (const <LiveRow>[], false);
  for (final r in rows.take(3)) {
    final pi = r.pi;
    if (pi == null) return (rows, false);
    final segCols = [for (var j = pi + 1; j < header.length; j++) if (header[j].isNotEmpty) j];
    if (segCols.isEmpty || !segCols.every((j) => j < r.cells.length && r.cells[j].isNotEmpty)) return (rows, false);
  }
  return (rows, true);
}

/// Окончателен ли протокол сегмента: у его строки в оглавлении есть судейские оценки.
/// Табло, которое оценок не выкладывает вовсе, считается окончательным сразу.
bool segmentFinal(String index, String segUrl) {
  final file = segUrl.split('/').last.toLowerCase();
  final page = index.replaceAll(_script, '');
  if (!page.contains('JudgesDetails')) return true;
  for (final r in _tr.allMatches(page)) {
    final row = r[1]!;
    if (row.toLowerCase().contains(file) && row.contains('JudgesDetails')) return true;
  }
  return false;
}

/// «Vladislav DIKIDZHI» → «Vladislav Dikidzhi»: так пишет иностранцев сборщик.
String _titled(String latin) => latin.replaceAllMapped(
  RegExp(r"\b([A-ZÀ-Ý])([A-ZÀ-Ý'\-]+)\b"),
  (m) => '${m[1]}${m[2]!.toLowerCase()}',
);

class Live {
  static final _client = http.Client();

  static Future<String?> _get(String url) async {
    try {
      final r = await _client
          .get(Uri.parse(url), headers: {'Cache-Control': 'no-cache'})
          .timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) return null;
      // табло в UTF-8, но заголовок с кодировкой бывает не у всех
      return utf8.decode(r.bodyBytes, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  /// Свежие итоги старта с табло или null — на табло пока ничего нового нет.
  static Future<Start?> poll(Start s) async {
    final src = s.live;
    if (src == null || src.seg.isEmpty) return null;
    final page = await _get(src.seg);
    if (page == null) return null;
    final rows = segmentResults(page);
    if (rows == null || rows.isEmpty) return null;
    final index = await _get(src.idx);
    // оглавление не ответило — окончательным не считаем
    final done = index != null && segmentFinal(index, src.seg);
    String ru(String latin) => src.names[latin] ?? _titled(latin);
    final podium = [for (final r in rows.take(3)) Placing(r.place, ru(r.name), r.nation, r.points)];
    final places = {for (final r in rows) norm(ru(r.name)): r.place};
    List<Placing>? total;
    var finals = const <String, int>{};
    if (done && src.cat != null && s.total.isEmpty) {
      final cat = await _get(src.cat!);
      if (cat != null) {
        final (all, complete) = categoryResults(cat);
        if (complete) {
          total = [for (final r in all.take(3)) Placing(r.place, ru(r.name), r.nation, r.points)];
          finals = {for (final r in all) norm(ru(r.name)): r.place};
        }
      }
    }
    return s.withResults(podium: podium, provisional: !done, places: places, total: total, finals: finals);
  }
}
