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

/// Отслеживаемые спортсмены — выбор человека (пара — целиком или по одному из пары).
class Follow {
  final Set<String> names;
  final Set<String> _keys;

  /// На международных стартах — все россияне, все белорусы (отдельные переключатели).
  final bool russians, belarusians;
  Follow(Iterable<String> list, {this.russians = true, this.belarusians = true})
    : names = list.toSet(),
      _keys = {for (final n in list) norm(n)};
  static final none = Follow(const []);

  /// Код страны из табло — россиянин или белорус, которых человек отслеживает на международных.
  bool nation(String n) => (russians && isRussianNation(n)) || (belarusians && isBelarusianNation(n));

  bool has(String name) {
    if (_keys.isEmpty) return false;
    if (_keys.contains(norm(name))) return true;
    return name.contains(' / ') && name.split(' / ').any((m) => _keys.contains(norm(m.trim())));
  }
}

/// Россиянин или белорус по коду из табло: RUS, AIN2, BLR, AIN1, AIN, регион на стартах ФСР.
bool isOurNation(String n) => isRussianNation(n) || isBelarusianNation(n);

/// RUS, AIN2 (нейтральные россияне), AIN (без уточнения — у нас это россияне), регион ФСР.
bool isRussianNation(String n) => const {'RUS', 'AIN2', 'AIN'}.contains(n) || _isRussianRegion(n);
bool isBelarusianNation(String n) => const {'BLR', 'AIN1'}.contains(n);

class Skater {
  final String name;
  final String? time; // «19:30» по Москве
  final int? no;
  final int? warmup;
  final int? place; // место в сегменте, когда он прошёл
  final int? overall; // место в итоге вида — у события с итогом турнира
  final String nation; // код страны/команды из табло, нужен для подписи групп
  Skater(this.name, this.time, this.no, this.warmup, [this.place, this.overall, this.nation = '']);
  factory Skater.fromJson(Map o) =>
      Skater(o['name'], o['time'], o['no'], o['warmup'], o['place'], o['final'], o['nation'] ?? '');

  /// В списке у пар — только фамилии.
  String get short => name.contains(' / ') ? name.split(' / ').map((p) => p.trim().split(' ').last).join(' / ') : name;
}

/// Название группы участников по фактическим кодам из табло.
/// AIN2 отображаем как RUS, AIN1 — как BLR; региональные коды на стартах ФСР относятся к россиянам.
bool _isRussianRegion(String nation) =>
    nation.length == 3 &&
    nation.codeUnits.every((v) => (v >= 0x410 && v <= 0x42F) || v == 0x401 || v == 0x451);

String oursLabel(Iterable<Skater> skaters, {bool exitTimes = false, bool intl = true}) {
  var group = '';
  if (intl) {
    var russian = false;
    var belarusian = false;
    var others = false;
    for (final skater in skaters) {
      final nation = skater.nation.trim();
      if (nation == 'RUS' || nation == 'AIN2' || _isRussianRegion(nation)) {
        russian = true;
      } else if (nation == 'BLR' || nation == 'AIN1') {
        belarusian = true;
      } else {
        others = true;
      }
    }
    group = russian && belarusian
        ? 'Россияне и белорусы'
        : belarusian
            ? 'Белорусы'
            : russian
                ? 'Россияне'
                : '';
    // иностранцы здесь только потому, что человек их отслеживает
    if (others) group = group.isEmpty ? 'Отслеживаемые' : '$group, отслеживаемые';
  }
  // на российских стартах все россияне — группа не подписывается
  if (exitTimes) return group.isEmpty ? 'Выход на лёд' : '$group · выход на лёд';
  return group;
}

String _cleanVenue(Object? v) => ((v as String?) ?? '').replaceAll(RegExp(r'\s*(\.{2,}|…)+(?=\s*(,|$))'), '').trim();

class Start {
  final String id, tid, tournament, kind, level, seg, title, venue, src;
  final DateTime t0, t1;
  final bool intl;

  /// Региональная федерация (не федеральный старт): показываются, только если включено в настройках.
  final bool regional;
  final String region;
  final List<String> broadcast, athletes;

  /// Кого показывать в карточке: россияне и белорусы на международных стартах и все,
  /// кого человек отслеживает (см. [withFollow]).
  final List<Skater> ours;

  /// Весь состав со временем выхода и местами; пусто — данные старой версии сборщика.
  final List<Skater> field;
  Start.fromJson(Map<String, dynamic> j)
    : id = j['id'],
      tid = j['tid'],
      tournament = j['tournament'],
      kind = j['kind'],
      level = j['level'],
      seg = j['seg'],
      title = j['title'],
      venue = _cleanVenue(j['venue']),
      src = j['src'] ?? '',
      t0 = DateTime.parse(j['start']),
      t1 = DateTime.parse(j['end']),
      intl = j['intl'] == true,
      regional = j['tier'] == 'regional',
      region = '${j['region'] ?? ''}',
      broadcast = List<String>.from(j['broadcast'] ?? const []),
      athletes = List<String>.from(j['athletes'] ?? const []),
      ours = [for (final o in (j['ours'] as List? ?? const [])) Skater.fromJson(o)],
      field = [for (final o in (j['field'] as List? ?? const [])) Skater.fromJson(o)],
      podium = [for (final p in (j['podium'] as List? ?? const [])) Placing.fromJson(p)],
      total = [for (final p in (j['total'] as List? ?? const [])) Placing.fromJson(p)],
      provisional = j['provisional'] == true,
      facts = _uniqueFacts([
        for (final f in (j['facts'] as List? ?? const []))
          if (f is Map && (f['text'] as String? ?? '').isNotEmpty) Fact.fromJson(Map<String, dynamic>.from(f)),
      ]),
      live = j['live'] is Map ? LiveSrc.fromJson(Map<String, dynamic>.from(j['live'] as Map)) : null;

  /// Тот же старт с итогами, прочитанными с табло турнира (live.dart).
  Start._with(
    Start o, {
    required this.ours,
    required this.podium,
    required this.total,
    required this.provisional,
    List<Skater>? field,
  }) : field = field ?? o.field,
       id = o.id,
       tid = o.tid,
       tournament = o.tournament,
       kind = o.kind,
       level = o.level,
       seg = o.seg,
       title = o.title,
       venue = o.venue,
       src = o.src,
       t0 = o.t0,
       t1 = o.t1,
       intl = o.intl,
       regional = o.regional,
       region = o.region,
       broadcast = o.broadcast,
       athletes = o.athletes,
       facts = o.facts,
       live = o.live;

  Start withResults({
    required List<Placing> podium,
    required bool provisional,
    Map<String, int> places = const {},
    List<Placing>? total,
    Map<String, int> finals = const {},
  }) {
    Skater up(Skater o) =>
        Skater(o.name, o.time, o.no, o.warmup, places[norm(o.name)] ?? o.place, finals[norm(o.name)] ?? o.overall, o.nation);
    return Start._with(
      this,
      ours: [for (final o in ours) up(o)],
      field: [for (final o in field) up(o)],
      podium: podium,
      total: total ?? this.total,
      provisional: provisional,
    );
  }

  /// Карточка под выбор человека: на международных — россияне и белорусы и отслеживаемые,
  /// на российских — отслеживаемые.
  Start withFollow(Follow follow) {
    if (field.isEmpty) return this;
    return Start._with(
      this,
      ours: [for (final o in field) if ((intl && follow.nation(o.nation)) || follow.has(o.name)) o],
      podium: podium,
      total: total,
      provisional: provisional,
    );
  }

  /// В ленте по умолчанию: российский старт или международный, где есть кого показать.
  bool get shown => !intl || ours.isNotEmpty;

  /// Известно, кто стартует: заявка или протокол уже опубликованы. Пока нет — про отслеживаемых
  /// сказать ничего нельзя (российские старты до публикации стартового листа).
  bool get compositionKnown => field.isNotEmpty || athletes.isNotEmpty;

  /// Тройка пока промежуточная: протокол на табло, судейских оценок ещё нет.
  final bool provisional;

  /// Примечательное: рекорды, редкие прыжки, лучшие оценки сезона, взлёт по итогу.
  final List<Fact> facts;

  /// Адреса табло турнира — во время старта приложение читает итоги оттуда само.
  final LiveSrc? live;

  /// Итог окончательный — табло больше не опрашиваем.
  bool get settled => podium.isNotEmpty && !provisional && (live?.cat == null || total.isNotEmpty);

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

/// Примечательное в сегменте. who пустой — о турнире в целом («Весь пьедестал — россияне»).
class Fact {
  final String who, text, kind;
  Fact(this.who, this.text, this.kind);
  Fact.fromJson(Map<String, dynamic> j) : who = j['who'] ?? '', text = j['text'] ?? '', kind = j['kind'] ?? '';
}

/// Убирает одинаковые факты, пришедшие из результатов сегмента и общего итога.
/// Разные достижения одного спортсмена сохраняются.
List<Fact> _uniqueFacts(Iterable<Fact> source) {
  final seen = <String>{};
  return [
    for (final fact in source)
      if (seen.add(jsonEncode([
        fact.who.trim().toLowerCase(),
        fact.text.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase(),
      ])))
        fact,
  ];
}

/// Табло турнира (Swiss Timing): оглавление, страница сегмента, итог вида, первый сегмент
/// и имена латиницей → как их пишет приложение.
class LiveSrc {
  final String idx, seg;
  final String? cat, first;
  final Map<String, String> names;
  LiveSrc.fromJson(Map<String, dynamic> j)
    : idx = j['idx'] ?? '',
      seg = j['seg'] ?? '',
      cat = j['cat'],
      first = j['first'],
      names = {for (final e in (j['names'] as Map? ?? const {}).entries) '${e.key}': '${e.value}'};
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

  /// Россиянин или белорус: RUS, AIN2, BLR, AIN1; на российских стартах — регион.
  /// Простой AIN — неизвестно чей: показываем как иностранца, с кодом.
  bool get ours => nation == 'RUS' || nation == 'AIN2' || nation == 'BLR' || nation == 'AIN1' || RegExp(r'^[А-ЯЁ]{3}$').hasMatch(nation);
  String get short => name.contains(' / ') ? name.split(' / ').map((p) => p.trim().split(' ').last).join(' / ') : name;
}

/// Турнир, у которого ещё нет расписания по сегментам: только даты и место.
class Upcoming {
  final String tid, name, venue;
  final bool intl;

  /// Дни по Москве: «2026-10-15».
  final String start, end;
  final List<String> ours;

  /// Страна россиян и белорусов из заявки: имя → код (нет — считаем россиянином).
  final Map<String, String> oursNation;

  /// Весь заявленный состав (у международных) — для поиска и отслеживаемых.
  final List<String> athletes;
  Upcoming.fromJson(Map<String, dynamic> j)
    : tid = j['tid'] ?? '',
      name = j['name'] ?? '',
      venue = _cleanVenue(j['venue']),
      intl = j['intl'] == true,
      start = (j['start'] as String? ?? '').split('T').first,
      end = ((j['end'] ?? j['start']) as String? ?? '').split('T').first,
      ours = List<String>.from(j['ours'] ?? const []),
      oursNation = {for (final e in (j['ours_nation'] as Map? ?? const {}).entries) '${e.key}': '${e.value}'},
      athletes = List<String>.from(j['athletes'] ?? const []);

  Upcoming._(Upcoming u, this.ours)
    : oursNation = u.oursNation,
      tid = u.tid,
      name = u.name,
      venue = u.venue,
      intl = u.intl,
      start = u.start,
      end = u.end,
      athletes = u.athletes;

  /// Россияне и белорусы из заявки (если их отслеживают) плюс отслеживаемые.
  Upcoming withFollow(Follow f) => Upcoming._(
    this,
    {
      for (final o in ours) if (!intl || f.nation(oursNation[o] ?? 'RUS') || f.has(o)) o,
      ...athletes.where(f.has),
    }.toList()..sort(),
  );

  bool get shown => !intl || ours.isNotEmpty;

  /// Идёт ли турнир в этот день.
  bool covers(String day) => start.isNotEmpty && day.compareTo(start) >= 0 && day.compareTo(end) <= 0;
}

class Schedule {
  final List<Start> starts;
  final DateTime generated;

  /// Все источники ответили при последнем сборе.
  final bool complete;
  final bool fromCache;

  /// Фотографии спортсменов: «Имя Фамилия» → миниатюра на сайте (photos/…) или адрес.
  final Map<String, String> photos;

  /// Турниры без расписания по сегментам, по дате начала.
  final List<Upcoming> upcoming;

  /// Источники последнего сбора: «ФФККР» → ok / fail.
  final Map<String, String> sources;

  /// Наши, за которыми следит сборщик.
  final List<String> watchlist;

  /// Все, кого видел сборщик (российские МС/КМС и участники международных турниров):
  /// из них идёт поиск по спортсмену в фильтре.
  final List<String> roster;

  /// Справочник спортсменов со страной и видами: имя → человек (пара — одной записью).
  final Map<String, Person> people;
  Schedule(
    this.starts,
    this.generated,
    this.complete,
    this.fromCache, {
    this.photos = const {},
    this.upcoming = const [],
    this.sources = const {},
    this.watchlist = const [],
    this.roster = const [],
    this.people = const {},
  });

  /// Все имена для поиска: справочник, список сборщика и следимые.
  Set<String> get searchable => {...people.keys, ...roster, ...watchlist};

  String? photoOf(String name) {
    final p = photos[name];
    if (p == null || p.isEmpty) return null;
    return p.startsWith('http') ? p : Uri.parse(dataUrl).resolve('../$p').toString();
  }

  static Schedule parse(String body, {bool fromCache = false}) {
    final j = jsonDecode(body) as Map<String, dynamic>;
    final starts = [for (final e in j['events'] as List) Start.fromJson(e)]..sort((a, b) => a.t0.compareTo(b.t0));
    final upcoming = [
      for (final u in (j['upcoming'] as List? ?? const [])) Upcoming.fromJson(Map<String, dynamic>.from(u as Map)),
    ]..removeWhere((u) => u.name.isEmpty || u.start.isEmpty);
    upcoming.sort((a, b) => a.start.compareTo(b.start));
    return Schedule(
      starts,
      DateTime.parse(j['generated']),
      j['complete'] != false,
      fromCache,
      photos: Map<String, String>.from(j['photos'] ?? const {}),
      upcoming: upcoming,
      sources: {for (final e in (j['sources'] as Map? ?? const {}).entries) '${e.key}': '${e.value}'},
      watchlist: List<String>.from(j['watchlist'] ?? const []),
      roster: List<String>.from(j['roster'] ?? const []),
      people: {
        for (final p in (j['people'] as List? ?? const []))
          if (p is Map && p['n'] is String) '${p['n']}': Person('${p['n']}', '${p['c'] ?? ''}', '${p['k'] ?? ''}'),
      },
    );
  }

  /// Под выбор человека: кого показывать в карточках и что попадает в ленту.
  Schedule withFollow(Follow f) => Schedule(
    [for (final s in starts) s.withFollow(f)],
    generated,
    complete,
    fromCache,
    photos: photos,
    upcoming: [for (final u in upcoming) u.withFollow(f)],
    sources: sources,
    watchlist: watchlist,
    roster: roster,
    people: people,
  );

  /// То же расписание с другими стартами (итоги с табло).
  Schedule withStarts(List<Start> list) => Schedule(
    list,
    generated,
    complete,
    fromCache,
    photos: photos,
    upcoming: upcoming,
    sources: sources,
    watchlist: watchlist,
    roster: roster,
    people: people,
  );

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

  /// Для синхронизации (sync.dart): те же preferences, отдельные ключи.
  static SharedPreferences get raw => _p;

  // Уведомления: правила (строка JSON, разбирает reminders.dart) и ручные исключения.
  static String? get rulesJson => _p.getString('n.rules');
  static Future<void> setRulesJson(String v) => _p.setString('n.rules', v);
  static Set<String> get forcedOn => (_p.getStringList('n.on') ?? const []).toSet();
  static Set<String> get forcedOff => (_p.getStringList('n.off') ?? const []).toSet();
  static Future<void> setForced(Set<String> on, Set<String> off) async {
    await _p.setStringList('n.on', on.toList());
    await _p.setStringList('n.off', off.toList());
  }

  /// Уведомления Android переведены на свои (старые, от общего плагина, убраны).
  static bool get alertsMigrated => _p.getBool('n.mig2') ?? false;
  static Future<void> setAlertsMigrated() => _p.setBool('n.mig2', true);

  /// Разрешение у системы уже спрашивали.
  static bool get asked => _p.getBool('n.asked') ?? false;
  static Future<void> setAsked() => _p.setBool('n.asked', true);

  // Лента и оформление.
  static bool get showDone => _p.getBool('f.done') ?? true;
  static Future<void> setShowDone(bool v) => _p.setBool('f.done', v);
  static bool get regional => _p.getBool('f.regional') ?? false;
  static Future<void> setRegional(bool v) => _p.setBool('f.regional', v);

  /// system, light, dark
  static String get theme => _p.getString('theme') ?? 'system';
  static Future<void> setTheme(String v) => _p.setString('theme', v);

  static Set<String> get kinds => (_p.getStringList('f.kinds') ?? const []).toSet();
  static Set<String> get tids => (_p.getStringList('f.tids') ?? const []).toSet();
  static Set<String> get athletes => (_p.getStringList('f.athletes') ?? const []).toSet();
  static Set<String> get levels => (_p.getStringList('f.levels') ?? const []).toSet();
  static Set<String> get scope => (_p.getStringList('f.scope') ?? const []).toSet();

  /// Отслеживаемые; null — человек ещё не выбирал (тогда — список сборщика).
  static List<String>? get follow => _p.getStringList('follow');
  static bool get followRussians => _p.getBool('follow.ru') ?? true;
  static bool get followBelarusians => _p.getBool('follow.by') ?? true;
  /// null — снова «по умолчанию»: ключа нет, действует список сборщика.
  static Future<void> setFollow(Iterable<String>? v, {required bool russians, required bool belarusians}) async {
    if (v == null) {
      await _p.remove('follow');
    } else {
      await _p.setStringList('follow', v.toList());
    }
    await _p.setBool('follow.ru', russians);
    await _p.setBool('follow.by', belarusians);
  }

  /// Отслеживаемые в фоне (без состояния приложения).
  static Follow followOr(List<String> fallback) =>
      Follow(follow ?? fallback, russians: followRussians, belarusians: followBelarusians);
  static Future<void> setFilters(Filters f) async {
    await _p.setStringList('f.kinds', f.kinds.toList());
    await _p.setStringList('f.tids', f.tids.toList());
    await _p.setStringList('f.athletes', f.athletes.toList());
    await _p.setStringList('f.levels', f.levels.toList());
    await _p.setStringList('f.scope', f.scope.toList());
  }
}

String norm(String s) => s.toLowerCase().replaceAll('ё', 'е');

/// Спортсмен из справочника: страна (код ISU, у россиян RUS) и виды (w m p d).
class Person {
  final String name, nation, kinds;
  const Person(this.name, this.nation, this.kinds);
}

/// Есть ли [who] среди [names]: точное имя или один из пары («Метелкина» в «Метелкина / Берулава»).
bool namesInclude(Iterable<String> names, String who) {
  final w = norm(who);
  for (final n in names) {
    if (norm(n) == w) return true;
    if (n.contains(' / ') && n.split(' / ').any((m) => norm(m.trim()) == w)) return true;
  }
  return false;
}

const _cyr = {
  'а': 'a', 'б': 'b', 'в': 'v', 'г': 'g', 'д': 'd', 'е': 'e', 'ё': 'e', 'ж': 'zh', 'з': 'z', 'и': 'i',
  'й': 'i', 'к': 'k', 'л': 'l', 'м': 'm', 'н': 'n', 'о': 'o', 'п': 'p', 'р': 'r', 'с': 's', 'т': 't',
  'у': 'u', 'ф': 'f', 'х': 'kh', 'ц': 'ts', 'ч': 'ch', 'ш': 'sh', 'щ': 'shch', 'ъ': '', 'ы': 'y',
  'ь': '', 'э': 'e', 'ю': 'iu', 'я': 'ia',
};

/// Слово латиницей в одном написании: «Гладки» и «Gladki», «Шимада» и «Shimada» дают одно.
/// Так же сводит сборщик (scraper/names.py, norm_lat).
String latinKey(String word) {
  var s = word.toLowerCase().split('').map((c) => _cyr[c] ?? c).join();
  s = s
      .replaceAll(RegExp('[àáâãäå]'), 'a')
      .replaceAll(RegExp('[èéêë]'), 'e')
      .replaceAll(RegExp('[ìíîï]'), 'i')
      .replaceAll(RegExp('[òóôõöø]'), 'o')
      .replaceAll(RegExp('[ùúûü]'), 'u')
      .replaceAll(RegExp('[çč]'), 'c')
      .replaceAll(RegExp('[šś]'), 's')
      .replaceAll(RegExp('[žź]'), 'z')
      .replaceAll(RegExp('[^a-z]'), '');
  for (final (a, b) in const [
    ('x', 'ks'), ('shch', 'sch'), ('kh', 'h'), ('ye', 'e'), ('yo', 'e'), ('iy', 'i'), ('yi', 'i'),
    ('y', 'i'), ('j', 'i'), ('w', 'v'), ('ph', 'f'), ('ie', 'e'),
  ]) {
    s = s.replaceAll(a, b);
  }
  return s.replaceAllMapped(RegExp(r'(.)\1+'), (m) => m[1]!);
}

List<String> _nameWords(String name) =>
    name.split(RegExp(r'[\s/\-]+')).where((w) => w.isNotEmpty).map(latinKey).where((w) => w.isNotEmpty).toList();

/// Подходит ли имя под запрос: каждое слово запроса — начало какого-то слова имени,
/// на любом алфавите («глад», «gladki», «Стефания Гладки»).
bool nameMatches(String name, String query) {
  final q = _nameWords(query);
  if (q.isEmpty) return false;
  final n = _nameWords(name);
  return q.every((w) => n.any((x) => x.startsWith(w)));
}

/// Найденные по запросу, лучшие сверху: фамилия с начала запроса, с фото, выступает впереди.
List<String> searchAthletes(Schedule data, String query, {Set<String> soon = const {}, int limit = 30}) {
  final q = _nameWords(query);
  if (q.isEmpty) return const [];
  // одно имя в разных источниках («Артём» и «Артем») — один раз; со стартов впереди — как там
  final seen = <String>{};
  final found = [
    for (final a in [...soon, ...data.people.keys, ...data.roster, ...data.watchlist])
      if (nameMatches(a, query) && seen.add(norm(a))) a,
  ];
  int score(String a) {
    final words = _nameWords(a);
    var s = 0;
    // фамилия — последнее слово каждого из пары
    final surnames = a.split(' / ').map((m) => _nameWords(m)).where((w) => w.isNotEmpty).map((w) => w.last);
    if (!surnames.any((w) => w.startsWith(q.first))) s += 4;
    if (!words.any((w) => w == q.first)) s += 1;
    if (a.split(' / ').every((m) => data.photoOf(m.trim()) == null)) s += 2;
    if (!soon.contains(a)) s += 2;
    return s;
  }
  final scored = {for (final a in found) a: score(a)};
  found.sort((a, b) {
    final c = scored[a]!.compareTo(scored[b]!);
    return c != 0 ? c : a.compareTo(b);
  });
  return found.take(limit).toList();
}

/// Фильтр ленты: виды, уровень, российские или международные, турниры, спортсмены.
/// Только то, что видно в ленте и в месяце, — к уведомлениям отношения не имеет.
/// Пустой набор — без ограничения.
class Filters {
  final Set<String> kinds, tids, athletes;
  final Set<String> levels; // senior, junior
  final Set<String> scope; // russian, intl
  const Filters(this.kinds, this.tids, this.athletes, {this.levels = const {}, this.scope = const {}});
  static const none = Filters({}, {}, {});
  bool get any => kinds.isNotEmpty || tids.isNotEmpty || athletes.isNotEmpty || levels.isNotEmpty || scope.isNotEmpty;
  int get count => kinds.length + tids.length + athletes.length + levels.length + scope.length;

  /// Человек сам назвал турнир или спортсмена — показываем и международные старты без россиян.
  bool get explicit => tids.isNotEmpty || athletes.isNotEmpty;

  bool _scope(bool intl) => scope.isEmpty || scope.contains(intl ? 'intl' : 'russian');

  bool _has(Iterable<String> names) {
    final list = names.toList();
    return athletes.any((a) => namesInclude(list, a));
  }

  bool pass(Start s) {
    if (!explicit && !s.shown) return false;
    if (!_scope(s.intl)) return false;
    if (levels.isNotEmpty && !levels.contains(s.level)) return false;
    if (kinds.isNotEmpty && !kinds.contains(s.kind)) return false;
    if (tids.isNotEmpty && !tids.contains(s.tid)) return false;
    if (athletes.isNotEmpty && !_has([...s.athletes, ...s.ours.map((o) => o.name), ...s.field.map((o) => o.name)])) return false;
    return true;
  }

  /// Турнир без расписания: виды у него неизвестны — отсекают выбор турниров и заявка наших.
  bool passUpcoming(Upcoming u) =>
      (explicit || u.shown) &&
      _scope(u.intl) &&
      (tids.isEmpty || tids.contains(u.tid)) &&
      (athletes.isEmpty || _has([...u.ours, ...u.athletes]));
}
