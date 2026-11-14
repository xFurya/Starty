// Архив прошлых сезонов. Старты прошлых лет лежат на сайте по месяцам (data/past/<гггг-мм>.json,
// собирает scraper/history.py) в том же виде, что нынешнее расписание, и подгружаются, когда человек
// долистал до месяца: карточка, места, тройка, протокол — как у нынешних стартов.
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'data.dart';

/// Адрес файла архива рядом с events.json.
String pastUrl(String file) => Uri.parse(dataUrl).resolve('past/$file').toString();

/// «2024-12» для дня или момента.
String monthKey(DateTime t) => '${t.year}-${two(t.month)}';

/// Турнир прошлых лет, у которого на табло нет времени сегментов: в календаре стоит днями
/// проведения, итоги открываются протоколом.
class PastTournament {
  final String tid, name, start, end, venue;
  final bool intl;

  /// Файл протокола (с приставкой past/, см. [protocolUrl]).
  final String? proto;
  final List<String> kinds;
  const PastTournament({
    required this.tid,
    required this.name,
    required this.start,
    required this.end,
    required this.venue,
    required this.intl,
    required this.proto,
    required this.kinds,
  });

  static PastTournament? parse(Object? j) {
    if (j is! Map) return null;
    final tid = j['tid'], name = j['name'], start = j['start'];
    if (tid is! String || name is! String || start is! String || DateTime.tryParse(start) == null) return null;
    final end = j['end'] is String && DateTime.tryParse(j['end'] as String) != null ? j['end'] as String : start;
    return PastTournament(
      tid: tid,
      name: name,
      start: start,
      end: end.compareTo(start) < 0 ? start : end,
      venue: '${j['venue'] ?? ''}',
      intl: j['intl'] == true,
      proto: j['proto'] is String ? 'past/${j['proto']}' : null,
      kinds: [for (final k in (j['kinds'] as List? ?? const [])) '$k'],
    );
  }

  bool covers(String day) => day.compareTo(start) >= 0 && day.compareTo(end) <= 0;

  /// Запись для списка дня: тот же вид, что у турнира без расписания.
  Upcoming get asUpcoming => Upcoming.fromJson({'tid': tid, 'name': name, 'start': start, 'end': end, 'venue': venue, 'intl': intl});

  /// Старт-заглушка, чтобы открыть протокол турнира: экрану протокола нужен старт, а не турнир.
  Start get asStart => Start.fromJson({
    'id': '$tid:all',
    'tid': tid,
    'tournament': name,
    'kind': kinds.isEmpty ? 'women' : kinds.first,
    'level': 'senior',
    'seg': 'КП',
    'title': name,
    'start': '${start}T12:00:00+03:00',
    'end': '${end}T12:00:00+03:00',
    'venue': venue,
    'intl': intl,
    'proto': proto,
  });
}

class PastMonth {
  final String month;
  final List<Start> starts;
  final List<PastTournament> tournaments;
  const PastMonth(this.month, this.starts, this.tournaments);

  /// Файл месяца → старты и турниры; битые записи пропускаются, а не роняют месяц.
  static PastMonth parse(String month, String body) {
    final j = jsonDecode(body);
    if (j is! Map || j['v'] != 1) throw const FormatException('версия архива');
    final starts = <Start>[];
    for (final e in (j['events'] as List? ?? const [])) {
      if (e is! Map) continue;
      try {
        final m = Map<String, dynamic>.from(e);
        // протоколы архива лежат отдельно от нынешних: past/protocols
        if (m['proto'] is String) m['proto'] = 'past/${m['proto']}';
        starts.add(Start.fromJson(m));
      } catch (_) {}
    }
    starts.sort((a, b) => a.t0.compareTo(b.t0));
    return PastMonth(month, starts, [
      for (final t in (j['tournaments'] as List? ?? const [])) ?PastTournament.parse(t),
    ]);
  }
}

class PastIndex {
  /// Первый и последний месяцы архива: «2018-08».
  final String first, last;

  /// Месяц → сколько в нём стартов.
  final Map<String, int> months;
  const PastIndex(this.first, this.last, this.months);

  bool has(String month) => months.containsKey(month);

  static PastIndex parse(String body) {
    final j = jsonDecode(body);
    if (j is! Map || j['v'] != 1 || j['months'] is! Map) throw const FormatException('индекс архива');
    final months = {
      for (final e in (j['months'] as Map).entries)
        if (RegExp(r'^\d{4}-\d{2}$').hasMatch('${e.key}') && e.value is int) '${e.key}': e.value as int,
    };
    if (months.isEmpty) throw const FormatException('индекс архива пуст');
    final keys = months.keys.toList()..sort();
    return PastIndex(keys.first, keys.last, months);
  }
}

/// Что известно о месяце архива.
enum PastState {
  /// В архиве этого месяца нет (или архив ещё не знаем) — показывать нечего.
  none,
  loading,
  ready,

  /// Не загрузился: нет связи.
  failed,
}

/// Загрузка архива: индекс один раз, месяцы — по запросу; загруженное держится в памяти.
class Archive {
  /// Клиент — подменяется в тестах.
  static http.Client client = http.Client();

  PastIndex? index;
  bool _indexBusy = false;

  /// Индекс запрашивали, и он не пришёл.
  bool indexFailed = false;
  final Map<String, PastMonth> _months = {};
  final Set<String> _busy = {}, _failed = {};

  PastMonth? month(String m) => _months[m];

  PastState stateOf(String m) {
    if (_months.containsKey(m)) return PastState.ready;
    if (_busy.contains(m) || (_indexBusy && index == null)) return PastState.loading;
    if (_failed.contains(m) || (index == null && indexFailed)) return PastState.failed;
    return PastState.none;
  }

  static Future<String?> _get(String url) async {
    try {
      final r = await client.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
      return r.statusCode == 200 ? utf8.decode(r.bodyBytes) : null;
    } catch (_) {
      return null;
    }
  }

  /// Индекс архива; null — не получили. Повторный вызов после неудачи пробует снова.
  Future<PastIndex?> loadIndex() async {
    if (index != null || _indexBusy) return index;
    _indexBusy = true;
    try {
      // индекс меняется раз в сезон, но узнать о пополнении стоит в тот же час
      final body = await _get('${pastUrl('index.json')}?t=${DateTime.now().millisecondsSinceEpoch ~/ 3600000}');
      if (body != null) index = PastIndex.parse(body);
      indexFailed = index == null;
    } catch (_) {
      indexFailed = true;
    } finally {
      _indexBusy = false;
    }
    return index;
  }

  /// Месяц архива: true — что-то изменилось (загрузился или не загрузился), false — запрос не нужен.
  Future<bool> load(String m) async {
    if (_months.containsKey(m) || _busy.contains(m)) return false;
    final idx = index ?? await loadIndex();
    if (idx == null) return true;
    if (!idx.has(m) || _months.containsKey(m) || _busy.contains(m)) return false;
    _busy.add(m);
    _failed.remove(m);
    try {
      final body = await _get(pastUrl('$m.json'));
      if (body == null) {
        _failed.add(m);
      } else {
        _months[m] = PastMonth.parse(m, body);
      }
    } catch (_) {
      _failed.add(m);
    } finally {
      _busy.remove(m);
    }
    return true;
  }
}
