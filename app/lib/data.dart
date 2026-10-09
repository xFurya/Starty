// Данные: расписание с GitHub Pages, копия на устройстве, время по Москве.
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

const dataUrl = String.fromEnvironment('DATA_URL', defaultValue: 'https://xfurya.github.io/Starty/data/events.json');

/// Для скриншотов: подменить «сейчас».
const _fakeNow = String.fromEnvironment('NOW');
DateTime now() => _fakeNow.isEmpty ? DateTime.now() : DateTime.parse(_fakeNow);

/// Московское время: UTC+3 круглый год.
DateTime msk(DateTime t) => t.toUtc().add(const Duration(hours: 3));
String two(int n) => n.toString().padLeft(2, '0');
String hm(DateTime t) {
  final m = msk(t);
  return '${two(m.hour)}:${two(m.minute)}';
}

/// Ключ дня по Москве: 2026-10-09.
String dayKey(DateTime t) {
  final m = msk(t);
  return '${m.year}-${two(m.month)}-${two(m.day)}';
}

const months = [
  'января',
  'февраля',
  'марта',
  'апреля',
  'мая',
  'июня',
  'июля',
  'августа',
  'сентября',
  'октября',
  'ноября',
  'декабря',
];
const monthsNom = [
  'Январь',
  'Февраль',
  'Март',
  'Апрель',
  'Май',
  'Июнь',
  'Июль',
  'Август',
  'Сентябрь',
  'Октябрь',
  'Ноябрь',
  'Декабрь',
];
const weekdays = ['понедельник', 'вторник', 'среда', 'четверг', 'пятница', 'суббота', 'воскресенье'];
const weekdaysShort = ['пн', 'вт', 'ср', 'чт', 'пт', 'сб', 'вс'];

class Skater {
  final String name;
  final String? time; // «19:30» по Москве
  final int? no;
  final int? warmup;
  final int? place; // место в сегменте, когда он прошёл
  Skater(this.name, this.time, this.no, this.warmup, [this.place]);

  /// В списке у пар — только фамилии.
  String get short => name.contains(' / ') ? name.split(' / ').map((p) => p.trim().split(' ').last).join(' / ') : name;
}

class Start {
  final String id, tid, tournament, kind, level, seg, title, venue, src;
  final DateTime t0, t1;
  final bool intl;
  final List<String> broadcast, athletes;
  final List<Skater> ours;
  Start.fromJson(Map<String, dynamic> j)
    : id = j['id'],
      tid = j['tid'],
      tournament = j['tournament'],
      kind = j['kind'],
      level = j['level'],
      seg = j['seg'],
      title = j['title'],
      venue = j['venue'] ?? '',
      src = j['src'] ?? '',
      t0 = DateTime.parse(j['start']),
      t1 = DateTime.parse(j['end']),
      intl = j['intl'] == true,
      broadcast = List<String>.from(j['broadcast'] ?? const []),
      athletes = List<String>.from(j['athletes'] ?? const []),
      ours = [
        for (final o in (j['ours'] as List? ?? const [])) Skater(o['name'], o['time'], o['no'], o['warmup'], o['place']),
      ],
      podium = [for (final p in (j['podium'] as List? ?? const [])) Placing.fromJson(p)],
      total = [for (final p in (j['total'] as List? ?? const [])) Placing.fromJson(p)];

  /// Первая тройка сегмента (пусто, пока сегмент не прошёл).
  final List<Placing> podium;

  /// Первая тройка турнира в этом виде — у последнего сегмента, когда вид закончен.
  final List<Placing> total;

  /// «женщины ПП» — часть названия после турнира.
  String get segment => title.substring(tournament.length).replaceFirst(RegExp(r'^\s*—\s*'), '');
  bool liveAt(DateTime t) => !t.isBefore(t0) && t.isBefore(t1);
  bool pastAt(DateTime t) => !t.isBefore(t1);
  String get day => dayKey(t0);

  /// Момент выхода нашего на лёд (время в списке — по Москве).
  DateTime? skateAt(Skater s) {
    if (s.time == null) return null;
    final p = s.time!.split(':');
    final m0 = msk(t0);
    var mins = (int.parse(p[0]) - m0.hour) * 60 + int.parse(p[1]) - m0.minute;
    if (mins < -120) mins += 24 * 60;
    return t0.add(Duration(minutes: mins));
  }
}

/// Место в итоговом протоколе: 1–3, имя (по-русски, если знаем), флаг, баллы.
class Placing {
  final int place;
  final String name, nation, points;
  Placing(this.place, this.name, this.nation, this.points);
  Placing.fromJson(Map<String, dynamic> j)
    : place = j['place'],
      name = j['name'],
      nation = j['nation'] ?? '',
      points = j['points'] ?? '';

  /// Наш: RUS или AIN2 (нейтральные россияне); на российских стартах — регион.
  bool get ours => nation == 'RUS' || nation == 'AIN2' || nation == 'AIN' || RegExp(r'^[А-ЯЁ]{3}$').hasMatch(nation);
  String get short => name.contains(' / ') ? name.split(' / ').map((p) => p.trim().split(' ').last).join(' / ') : name;
}

class Schedule {
  final List<Start> starts;
  final DateTime generated;
  final bool complete;
  final List<String> watchlist;
  final bool fromCache;

  /// Фотографии спортсменов: «Имя Фамилия» → миниатюра на сайте (photos/…) или адрес.
  final Map<String, String> photos;
  Schedule(this.starts, this.generated, this.complete, this.watchlist, this.fromCache, [this.photos = const {}]);

  String? photoOf(String name) {
    final p = photos[name];
    if (p == null || p.isEmpty) return null;
    return p.startsWith('http') ? p : Uri.parse(dataUrl).resolve('../$p').toString();
  }

  static Schedule parse(String body, {bool fromCache = false}) {
    final j = jsonDecode(body) as Map<String, dynamic>;
    final starts = [for (final e in j['events'] as List) Start.fromJson(e)]..sort((a, b) => a.t0.compareTo(b.t0));
    return Schedule(
      starts,
      DateTime.parse(j['generated']),
      j['complete'] != false,
      List<String>.from(j['watchlist'] ?? const []),
      fromCache,
      Map<String, String>.from(j['photos'] ?? const {}),
    );
  }

  Start? byId(String id) {
    for (final s in starts) {
      if (s.id == id) return s;
    }
    return null;
  }
}

class Repo {
  static const _key = 'schedule.json';

  /// Сохранённая копия — показываем сразу, пока идёт запрос.
  static Future<Schedule?> cached() async {
    final p = await SharedPreferences.getInstance();
    final s = p.getString(_key);
    if (s == null) return null;
    try {
      return Schedule.parse(s, fromCache: true);
    } catch (_) {
      return null;
    }
  }

  /// Свежая копия с сайта; при ошибке — null (останется сохранённая).
  static Future<Schedule?> fetch() async {
    try {
      final r = await http
          .get(Uri.parse('$dataUrl?t=${DateTime.now().millisecondsSinceEpoch ~/ 60000}'))
          .timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) return null;
      final body = utf8.decode(r.bodyBytes);
      final s = Schedule.parse(body);
      final p = await SharedPreferences.getInstance();
      await p.setString(_key, body);
      return s;
    } catch (_) {
      return null;
    }
  }
}

/// Что отметил человек и какие фильтры выбрал — хранится на устройстве.
class Prefs {
  static late SharedPreferences _p;
  static Future<void> init() async => _p = await SharedPreferences.getInstance();

  static Set<String> get watched => (_p.getStringList('watched') ?? const []).toSet();
  static Future<void> setWatched(Set<String> v) => _p.setStringList('watched', v.toList());

  /// Отслеживаемые спортсмены: уведомление перед каждым выходом.
  static Set<String> get followed => (_p.getStringList('followed') ?? const []).toSet();
  static Future<void> setFollowed(Set<String> v) => _p.setStringList('followed', v.toList());

  static Set<String> get kinds => (_p.getStringList('f.kinds') ?? const []).toSet();
  static Set<String> get tids => (_p.getStringList('f.tids') ?? const []).toSet();
  static Set<String> get athletes => (_p.getStringList('f.athletes') ?? const []).toSet();
  static Future<void> setFilters(Set<String> k, Set<String> t, Set<String> a) async {
    await _p.setStringList('f.kinds', k.toList());
    await _p.setStringList('f.tids', t.toList());
    await _p.setStringList('f.athletes', a.toList());
  }
}

String norm(String s) => s.toLowerCase().replaceAll('ё', 'е');

class Filters {
  final Set<String> kinds, tids, athletes;
  const Filters(this.kinds, this.tids, this.athletes);
  bool get any => kinds.isNotEmpty || tids.isNotEmpty || athletes.isNotEmpty;
  int get count => kinds.length + tids.length + athletes.length;

  bool pass(Start s) {
    if (kinds.isNotEmpty && !kinds.contains(s.kind)) return false;
    if (tids.isNotEmpty && !tids.contains(s.tid)) return false;
    if (athletes.isNotEmpty) {
      final names = {...s.athletes, ...s.ours.map((o) => o.name)}.map(norm).toSet();
      if (!athletes.any((a) => names.contains(norm(a)))) return false;
    }
    return true;
  }
}
