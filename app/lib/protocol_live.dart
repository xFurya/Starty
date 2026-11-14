// Протокол турнира, собранный на самом устройстве прямо с табло (Swiss Timing): без нашего сервера.
// Тот же разбор, что у сборщика (scraper/swisstiming.py и protocols.py): оглавление турнира →
// сегменты и итог вида → строки с местами, баллами, TES/PCS/сбавками. Окончательность — по ссылке
// на судейские оценки (JudgesDetails), как у сборщика. Детали оценок (элементы, компоненты) лежат
// в PDF: они берутся из прежнего файла, если там были, и не теряются при обновлении.
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'board_proxy.dart';
import 'data.dart';
import 'live.dart';

/// Итог обновления: файл как JSON и сколько страниц не прочиталось (сеть). null — собрать нечего.
class LiveProtocol {
  final Map<String, dynamic> json;
  final int failed;
  const LiveProtocol(this.json, this.failed);
}

class _Seg {
  final String name, url;
  final String? judges;
  _Seg(this.name, this.url, this.judges);
}

class _Cat {
  final String name;
  final String? results;
  final List<_Seg> segs = [];
  _Cat(this.name, this.results);
}

const _segEn = {
  'short program': 'КП',
  'free skating': 'ПП',
  'free program': 'ПП',
  'rhythm dance': 'РТ',
  'short dance': 'РТ',
  'free dance': 'ПТ',
};
const _segOrder = {'КП': 0, 'РТ': 0, 'ПП': 1, 'ПТ': 1};
const _totalCols = {'SP': 'КП', 'FS': 'ПП', 'FD': 'ПТ', 'RD': 'РТ', 'PT': 'РТ'};

final _pointsRe = RegExp(r'^\d{1,3}\.\d{2}$');
final _numRe = RegExp(r'^-?\d{1,3}\.\d{2}$');
final _statusRe = RegExp(r'^[A-Za-z]{2,4}$');
final _nationRe = RegExp(r'^[A-ZА-ЯЁ]{2,4}\d?(?:\s*/\s*[A-ZА-ЯЁ]{2,4}\d?)?$');
const _resultHeads = {'Pl.', 'Pl', 'Мес.', 'Место', 'Мест.', 'М.', 'FPl.', 'FPl'};
const _startingHeads = {'StN.', 'Ст.№', 'Ст. №', 'СН.', 'Pl.', 'Мес.', 'Место', 'М.', 'FPl.', 'FPl'};
const _nameHeads = {'Name', 'Имя', 'Спортсмен', 'Участник'};
const _nationHeads = {'Nation', 'Nat.', 'Регион', 'Страна', 'Нация'};
const _noHeads = {'СН.', 'СН', 'StN.', 'StN', 'Ст.№', 'Ст. №', 'Стартовый номер'};
const _segPoints = {'TSS', 'Сумма', 'Points', 'Баллы'};
const _catPoints = {'Points', 'Баллы', 'Сумма', 'Total', 'TSS'};
const _neutral = {'AIN1': 'BLR', 'AIN2': 'RUS'};

int? _col(List<String> header, Set<String> names, {bool prefix = false}) {
  for (var i = 0; i < header.length; i++) {
    final h = header[i].trim();
    if (names.contains(h) || (prefix && names.any(h.startsWith))) return i;
  }
  return null;
}

String _nationOf(String text) {
  final s = text.replaceAll(RegExp(r'\s+'), ' ').trim().replaceAll(RegExp(r'\s*/\s*'), ' / ');
  if (!_nationRe.hasMatch(s)) return '';
  return _neutral[s.toUpperCase()] ?? s;
}

/// Строка таблицы протокола → строка файла; null — не участник (легенда, разделитель).
/// Второе значение: баллы записаны с запятой — строка учтена как пропущенная.
(Map<String, dynamic>?, bool) _protocolRow(List<String> cells, List<String> header, Set<String> pointsHeads) {
  if (cells.length != header.length) return (null, false);
  final ni = _col(header, _nameHeads);
  final name = ni != null ? cells[ni] : '';
  if (name.isEmpty) return (null, false);
  final pi0 = _col(header, _resultHeads);
  final placeCell = pi0 != null ? cells[pi0] : '';
  int? place;
  String? status;
  final n = int.tryParse(placeCell);
  if (RegExp(r'^\d{1,3}$').hasMatch(placeCell) && n != null && n >= 1) {
    place = n;
  } else if (_statusRe.hasMatch(placeCell)) {
    status = placeCell;
  }
  if (place == null && status == null) return (null, false);
  int? no;
  final noi = _col(header, _noHeads);
  if (noi != null) {
    final m = RegExp(r'^#?(\d{1,3})$').firstMatch(cells[noi]);
    if (m != null) no = int.parse(m[1]!);
  }
  final ci = _col(header, _nationHeads);
  String? num(Set<String> names, RegExp re) {
    final j = _col(header, names, prefix: true);
    return j != null && re.hasMatch(cells[j]) ? cells[j] : null;
  }

  final pi = _col(header, pointsHeads, prefix: true);
  final rawPoints = pi != null ? cells[pi] : '';
  final points = _pointsRe.hasMatch(rawPoints) ? rawPoints : null;
  return (
    {
      'place': place,
      'status': status,
      'no': no,
      'name': name,
      'nation': ci != null ? _nationOf(cells[ci]) : '',
      'points': points,
      'tes': num({'TES'}, _numRe),
      'pcs': num({'PCS'}, _numRe),
      'ded': num({'Снижение', 'Ded'}, _numRe),
    },
    rawPoints.isNotEmpty && points == null,
  );
}

bool _hasComponents(List<String> h) => h.any((x) => x.trim().startsWith('TES') || x.trim().startsWith('PCS'));

/// Таблицы протокола страницы: (шапка, строки ниже шапки).
List<(List<String>, List<List<String>>)> _tables(String page) {
  final out = <(List<String>, List<List<String>>)>[];
  var opened = false;
  for (final cells in tabloRows(page)) {
    final first = cells.firstWhere((c) => c.isNotEmpty, orElse: () => '');
    if (_col(cells, _nameHeads) != null && !RegExp(r'^\d+$').hasMatch(first)) {
      opened = _resultHeads.contains(first);
      if (opened) out.add((cells, <List<String>>[]));
    } else if (opened) {
      out.last.$2.add(cells);
    }
  }
  return out;
}

class _Parsed {
  String table = 'results'; // results | starting | empty | format
  List<String> header = const [];
  final rows = <Map<String, dynamic>>[];
  final kept = <List<String>>[];
  int skipped = 0;
}

_Parsed _protocol(String page, Set<String> pointsHeads, {required bool segment}) {
  final out = _Parsed();
  final tables = [for (final t in _tables(page)) if (t.$2.isNotEmpty) t];
  if (tables.isEmpty) {
    final starting = tabloRows(page).any((r) => r.any(_startingHeads.contains));
    out.table = starting ? 'starting' : 'empty';
    return out;
  }
  final matching = [for (final t in tables) if (_hasComponents(t.$1) == segment) t];
  final (List<String>, List<List<String>>) pick;
  if (matching.length == 1) {
    pick = matching.first;
  } else if (tables.length == 1) {
    pick = tables.first;
  } else {
    out.table = 'format';
    return out;
  }
  out.header = pick.$1;
  final seen = <String>{};
  for (final cells in pick.$2) {
    final (row, badPoints) = _protocolRow(cells, pick.$1, pointsHeads);
    if (row == null) continue;
    final key = '${row['place'] ?? row['status']}|${row['name']}';
    if (!seen.add(key)) {
      out.skipped++;
      continue;
    }
    if (badPoints) out.skipped++;
    row['i'] = out.rows.length + 1;
    out.rows.add(row);
    out.kept.add(cells);
  }
  if (out.rows.isEmpty) {
    out.table = pick.$1.any(_startingHeads.contains) ? 'starting' : 'empty';
  }
  return out;
}

/// Оглавление турнира: категории со ссылками на сегменты, оценки судей и итог вида.
List<_Cat> _parseIndex(String page, Uri base) {
  final cats = <_Cat>[];
  _Cat? cur;
  var inSchedule = false;
  for (final (cells, links) in tabloRowsWithLinks(page)) {
    final joined = cells.join(' ');
    if (RegExp('Time Schedule|Расписание').hasMatch(joined) && links.isEmpty) inSchedule = true;
    if (inSchedule) continue;
    String? link(RegExp re) => links.where(re.hasMatch).firstOrNull;
    final catLink = link(RegExp(r'CAT\d+EN\.htm', caseSensitive: false));
    final segLink = link(RegExp(r'^SEG\d+\.htm$', caseSensitive: false));
    final first = cells.firstWhere((c) => c.isNotEmpty, orElse: () => '');
    if (catLink != null) {
      final res = link(RegExp(r'CAT\d+RS\.htm', caseSensitive: false));
      cur = _Cat(first, res == null ? null : base.resolve(res).toString());
      cats.add(cur);
    } else if (segLink != null && cur != null) {
      final judges = link(RegExp('JudgesDetails'));
      cur.segs.add(_Seg(first, base.resolve(segLink).toString(), judges == null ? null : base.resolve(judges).toString()));
    }
  }
  return cats;
}

/// Код сегмента по названию — английскому (ISU) или русскому (ФФККР, ФФКМ: «Короткая программа»,
/// «Ритм-танец», «Произвольный танец»), как у сборщика (build.seg_code, fsr.segment_of).
String? _segCode(String name) {
  final n = fixScript(name).trim().toLowerCase();
  final en = _segEn[n];
  if (en != null) return en;
  if (RegExp(r'ритм|ритмическ').hasMatch(n)) return 'РТ';
  if (RegExp(r'произвольн\w*\s+танец|произвольный\s+т').hasMatch(n)) return 'ПТ';
  if (RegExp(r'коротк').hasMatch(n)) return 'КП';
  if (RegExp(r'произвольн').hasMatch(n)) return 'ПП';
  return null;
}

/// Латинские буквы, набранные вместо кириллицы (табло ФФКМ: «Oдинoчнoe», «KMC»): слово с кириллицей —
/// целиком кириллицей; «MC»/«KMC» — «МС»/«КМС» (swisstiming.fix_script).
String fixScript(String s) => s.replaceAllMapped(RegExp(r'\S+'), (m) {
  final w = m[0]!;
  final cyr = RegExp('[А-Яа-яЁё]').hasMatch(w), lat = RegExp('[A-Za-z]').hasMatch(w);
  if ((cyr && lat) || RegExp(r'^K?MC[,.;:]?$').hasMatch(w)) {
    const from = 'AaBEeKMHOoPpCcTXxy', to = 'АаВЕеКМНОоРрСсТХху';
    return w.split('').map((ch) {
      final i = from.indexOf(ch);
      return i < 0 ? ch : to[i];
    }).join();
  }
  return w;
});

/// Вид и уровень по названию категории — ISU по-английски или ФФККР по-русски («Мужчины - МС»,
/// «Девушки - КМС», «Танцы на льду - МС»); null — не наша категория (разряды, дети, любители).
(String, String)? _classify(String name) {
  final n = fixScript(name).toLowerCase();
  if (RegExp('[а-яё]').hasMatch(n)) {
    // ниже КМС в протокол не берём, как сборщик (fsr.low_level)
    if (RegExp(r'разряд|девочк|мальчик|спецпрограмм|юношеск|любител|новичк').hasMatch(n)) return null;
    final String kind;
    if (n.contains('танц')) {
      kind = 'dance';
    } else if (n.contains('пар')) {
      kind = 'pairs';
    } else if (RegExp(r'девушк|юниорк|женщин').hasMatch(n)) {
      kind = 'women';
    } else if (RegExp(r'юнош|юниор|мужчин').hasMatch(n)) {
      kind = 'men';
    } else {
      return null;
    }
    final junior = RegExp(r'(^|[^а-яё])кмс([^а-яё]|$)').hasMatch(n) || RegExp(r'девушк|юниорк|юнош|юниор').hasMatch(n);
    final senior = RegExp(r'(^|[^а-яёк])мс([^а-яё]|$)').hasMatch(n) || RegExp(r'женщин|мужчин').hasMatch(n);
    return (kind, senior || !junior ? 'senior' : 'junior');
  }
  final level = n.contains('junior') ? 'junior' : 'senior';
  if (RegExp(r'novice|basic|intermediate|advanced|adult|masters|cubs|chicks|juvenile|synchro|solo').hasMatch(n)) return null;
  if (n.contains('ice dance') || n.contains('dance')) return ('dance', level);
  if (n.contains('pair')) return ('pairs', level);
  if (n.contains('women') || n.contains('ladies') || n.contains('girls')) return ('women', level);
  if (n.contains('men') || n.contains('boys')) return ('men', level);
  return null;
}

String _norm(String s) => personKey(s);

class ProtocolLive {
  /// Клиент — подменяется в тестах.
  static http.Client client = http.Client();

  /// Страница табло и её время (когда табло её обновило); не прочиталась — (null, null).
  static Future<(String?, DateTime?)> _page(String url, void Function() fail) async {
    try {
      final r = await client.get(Uri.parse(boardUrl(url)), headers: BoardProxy.headers).timeout(const Duration(seconds: 15));
      BoardProxy.saw(r);
      if (r.statusCode == 200) {
        final page = decodeTablo(r.bodyBytes);
        return (page, boardStamp(page, lastModified: r.headers['last-modified']));
      }
      if (r.statusCode != 404 && r.statusCode != 410) fail();
    } catch (_) {
      BoardProxy.failed();
      fail();
    }
    return (null, null);
  }

  /// Файл турнира со свежими страницами табло. [cached] — прежний файл (его детали оценок и имена
  /// сохраняются), [starts] — старты этого турнира (время сегментов и русские имена).
  /// null — оглавление не прочиталось или распознать нечего.
  static Future<LiveProtocol?> build({
    required String tid,
    required String tournament,
    required String idx,
    required Iterable<Start> starts,
    Map<String, dynamic>? cached,
    required DateTime now,
  }) async {
    var failed = 0;
    void fail() => failed++;
    final (page, _) = await _page(idx, fail);
    if (page == null) return null;
    final cats = _parseIndex(page, Uri.parse(idx));
    if (cats.isEmpty) return null;

    // время сегментов: из событий (kind|level|code → начало, конец); конец — с поправкой на темп,
    // если старт затянулся: иначе идущий сегмент назывался бы «промежуточным» посреди прокатов
    final times = <String, (DateTime, DateTime)>{
      for (final s in starts) '${s.kind}|${s.level}|${s.seg}': (s.t0, s.t1),
    };
    // имена: как в прежнем файле и расписании, иначе фамилии капсом приводятся к обычному виду
    final known = <String, String>{};
    void learn(String n) {
      if (n.isNotEmpty) known[_norm(n)] = n;
    }

    for (final s in starts) {
      for (final f in s.field) {
        learn(f.name);
      }
      for (final e in (s.live?.names ?? const <String, String>{}).entries) {
        known[_norm(e.key)] = e.value;
      }
    }
    final oldCats = <String, Map<String, dynamic>>{
      for (final c in (cached?['categories'] as List? ?? const []))
        if (c is Map) '${c['kind']}|${c['level']}': Map<String, dynamic>.from(c),
    };
    for (final c in oldCats.values) {
      for (final sg in (c['segments'] as List? ?? const [])) {
        for (final r in ((sg as Map)['rows'] as List? ?? const [])) {
          learn('${(r as Map)['name']}');
        }
      }
    }
    String nameOf(String raw) => known[_norm(raw)] ?? titledName(raw);

    final marks = cats.any((c) => c.segs.any((s) => s.judges != null));
    // все категории — разом: каждая лишняя секунда ожидания — секунда опоздания протокола
    final built = await Future.wait([
      for (final c in cats) _category(c, oldCats, times, now, nameOf, fail),
    ]);
    final outCats = [for (final c in built) ?c];
    if (outCats.isEmpty) return null;
    final doc = <String, dynamic>{
      'v': cached?['v'] ?? 1,
      'tid': tid,
      'tournament': tournament,
      'src': idx,
      'built': now.toUtc().toIso8601String(),
      'marks': marks,
      'categories': outCats,
    };
    return LiveProtocol(doc, failed);
  }

  /// Категория турнира: сегменты (их страницы — разом) и итог вида; не наша категория — null.
  static Future<Map<String, dynamic>?> _category(
    _Cat c,
    Map<String, Map<String, dynamic>> oldCats,
    Map<String, (DateTime, DateTime)> times,
    DateTime now,
    String Function(String) nameOf,
    void Function() fail,
  ) async {
    {
      final kl = _classify(c.name);
      if (kl == null) return null;
      final oc = oldCats['${kl.$1}|${kl.$2}'];
      final oldSegs = <String, Map<String, dynamic>>{
        for (final s in (oc?['segments'] as List? ?? const []))
          if (s is Map) '${s['code']}': Map<String, dynamic>.from(s),
      };
      final codes = [for (final s in c.segs) _segCode(s.name)];
      final lastOrder = codes.whereType<String>().map((x) => _segOrder[x]!).fold<int?>(null, (m, v) => m == null || v > m ? v : m);
      final recs = await Future.wait([
        for (var i = 0; i < c.segs.length; i++)
          if (codes[i] != null) _segment(c.segs[i], codes[i]!, kl, times, oldSegs[codes[i]!], now, nameOf, fail),
      ]);
      final segCodes = codes.whereType<String>().toList();
      final lastFinal = [
        for (var i = 0; i < recs.length; i++)
          if (_segOrder[segCodes[i]] == lastOrder && recs[i]['state'] == 'final') true,
      ].isNotEmpty;
      Map<String, dynamic>? total = oc?['total'] is Map ? Map<String, dynamic>.from(oc!['total'] as Map) : null;
      final started = recs.any((r) => r['state'] != 'scheduled');
      final totalDone = total != null && total['state'] == 'final';
      if (c.results != null && started && !totalDone) {
        final (t, stamp) = await _page(c.results!, fail);
        if (t != null) {
          final fresh = _total(t, lastFinal, nameOf);
          if (fresh != null) total = {...fresh, if (stamp != null) 'stamp': stamp.toUtc().toIso8601String()};
        }
      }
      return {'kind': kl.$1, 'level': kl.$2, 'name': c.name, 'segments': recs, 'total': total};
    }
  }

  static Future<Map<String, dynamic>> _segment(
    _Seg seg,
    String code,
    (String, String) kl,
    Map<String, (DateTime, DateTime)> times,
    Map<String, dynamic>? old,
    DateTime now,
    String Function(String) nameOf,
    void Function() fail,
  ) async {
    final t = times['${kl.$1}|${kl.$2}|$code'];
    DateTime? start = t?.$1, end = t?.$2;
    start ??= DateTime.tryParse('${old?['start']}');
    end ??= DateTime.tryParse('${old?['end']}');
    Map<String, dynamic> keepOld(String why) => old ?? _record(seg, code, start, end, 'empty', 'scheduled', null, const [], 0, null);
    // окончательный и с деталями — не перечитываем
    final oldRows = (old?['rows'] as List? ?? const []);
    final oldHasDetails = oldRows.any((r) => r is Map && r['els'] != null);
    if (old != null && old['state'] == 'final' && oldHasDetails) return old;
    if (start != null && now.isBefore(start)) {
      return _record(seg, code, start, end, 'empty', 'scheduled', null, const [], 0, old);
    }
    final (page, stamp) = await _page(seg.url, fail);
    if (page == null) return keepOld('net');
    final p = _protocol(page, _segPoints, segment: true);
    final hasRows = p.rows.isNotEmpty;
    String state;
    String? basis;
    if (p.table == 'format') {
      state = 'format';
    } else if (!hasRows) {
      state = seg.judges != null ? 'format' : 'not_published';
    } else if (seg.judges != null) {
      state = 'final';
      basis = 'judges';
    } else if (end != null && now.isBefore(end)) {
      state = 'in_progress';
    } else {
      state = 'provisional';
    }
    // страница временно пустая или хуже прежней — прежнее остаётся (как guard сборщика)
    if (old != null && old['state'] == 'final' && state != 'final') return old;
    if (old != null && !hasRows && oldRows.isNotEmpty) return old;
    // прокатов ещё нет, а табло уже пишет, кто выходит, — сегмент идёт
    if (!hasRows && state == 'not_published' && nextOnIce(page) != null) state = 'in_progress';
    final rows = [
      for (final r in p.rows) {...r, 'name': nameOf('${r['name']}')},
    ];
    final onIce = state == 'final' ? null : nextInfo(page);
    return _record(seg, code, start, end, p.table, state, basis, rows, p.skipped, old,
        stamp: stamp, next: onIce == null ? null : nameOf(onIce.name), warmup: onIce?.warmup ?? false);
  }

  /// Запись сегмента; детали оценок и бригада судей — из прежнего файла, если человек тот же.
  static Map<String, dynamic> _record(
    _Seg seg,
    String code,
    DateTime? start,
    DateTime? end,
    String table,
    String state,
    String? basis,
    List<Map<String, dynamic>> rows,
    int skipped,
    Map<String, dynamic>? old, {
    DateTime? stamp,
    String? next,
    bool warmup = false,
  }) {
    final oldByKey = <String, Map>{
      for (final r in (old?['rows'] as List? ?? const []))
        if (r is Map && r['els'] != null) '${r['place']}|${_norm('${r['name']}')}': r,
    };
    final merged = [
      for (final r in rows)
        () {
          final o = oldByKey['${r['place']}|${_norm('${r['name']}')}'];
          if (o == null) return r;
          return {
            ...r,
            for (final k in ['bv', 'els', 'comp', 'deds']) if (o[k] != null) k: o[k],
          };
        }(),
    ];
    return {
      'code': code,
      'name': seg.name,
      'start': start?.toIso8601String(),
      'end': end?.toIso8601String(),
      'page': seg.url,
      'judges': seg.judges ?? old?['judges'],
      'table': table,
      'state': state,
      'basis': basis,
      'skipped': skipped,
      'rows': merged,
      if (old?['panel'] != null) 'panel': old!['panel'],
      // время табло: когда страница сегмента обновилась — «Табло от 14:52» на экране протокола
      if ((stamp?.toUtc().toIso8601String() ?? old?['stamp']) case final String st) 'stamp': st,
      // кто выходит на лёд по табло («Далее: …»)
      'next': ?next,
      if (next != null && warmup) 'nextWarmup': true,
    };
  }

  /// Итог вида по странице CATnnnRS.htm; null — таблицы нет.
  static Map<String, dynamic>? _total(String page, bool lastFinal, String Function(String) nameOf) {
    final p = _protocol(page, _catPoints, segment: false);
    final pi = _col(p.header, _catPoints, prefix: true);
    final segCols = pi == null ? <int>[] : [for (var j = pi + 1; j < p.header.length; j++) if (p.header[j].isNotEmpty) j];
    final rows = <Map<String, dynamic>>[];
    for (var i = 0; i < p.rows.length; i++) {
      final r = p.rows[i];
      rows.add({
        'i': r['i'],
        'place': r['place'],
        'status': r['status'],
        'no': r['no'],
        'name': nameOf('${r['name']}'),
        'nation': r['nation'],
        'points': r['points'],
        'parts': [for (final j in segCols) p.kept[i][j].isEmpty ? null : p.kept[i][j]],
      });
    }
    final values = [for (final r in rows) ...(r['parts'] as List).whereType<String>()];
    final kind = values.isNotEmpty && values.every((v) => RegExp(r'^\d{1,3}$').hasMatch(v))
        ? 'places'
        : (values.isNotEmpty && values.every(_pointsRe.hasMatch) ? 'points' : 'unknown');
    final ranked = [for (final r in rows) if (r['place'] != null) r]..sort((a, b) => (a['place'] as int).compareTo(b['place'] as int));
    final complete = ranked.isNotEmpty && ranked.take(3).every((r) => (r['parts'] as List).every((x) => x != null));
    final String state;
    if (p.table == 'format') {
      state = 'format';
    } else if (p.table != 'results' || rows.isEmpty) {
      state = 'not_published';
    } else {
      state = complete && lastFinal ? 'final' : 'provisional';
    }
    return {
      'state': state,
      'complete': complete,
      'cols': [for (final j in segCols) _totalCols[p.header[j].replaceAll(RegExp(r'\s+'), '').toUpperCase()] ?? p.header[j]],
      'colsKind': kind,
      'rows': rows,
      'skipped': p.skipped,
    };
  }
}

/// Для тестов и отладки.
String liveProtocolJson(LiveProtocol p) => jsonEncode(p.json);
