// История выступлений спортсмена и статистика по ней (подписка): баллы по стартам, прыжки, уровни.
//
// Откуда прокаты. Сайт собирает их из протоколов ISU и ФФККР с сезона 2018/19 (scraper/history.py,
// файлы site/h/<xx>.json — по 256 частей, имя попадает в часть по контрольной сумме). Но свежий
// старт туда попадает только с полным сбором, а человеку он нужен сейчас — поэтому то, что
// приложение уже знает само (места и баллы из расписания, в том числе прочитанные с табло),
// добавляется на устройстве: [skatesFromSchedule], [mergeSkates].
//
// Правила честности: российские и международные оценки — разные ряды, их не сводят в одно число;
// «чисто» у прыжка — без отметок судей на нём, без падения и с неотрицательной оценкой элемента;
// у полного тёзки (двое с одним именем в одном сегменте) статистика не считается вовсе.
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'data.dart';

/// Элемент проката: код как в протоколе («3Lz!+3T<»), отметки («! <», «F»), GOE в баллах.
class SkateElement {
  final String code, info;
  final double goe;
  const SkateElement(this.code, this.info, this.goe);

  bool get fall => info.split(' ').contains('F');
}

/// Одно выступление в сегменте.
class Skate {
  /// День по табло («2024-12-19»); пусто — день неизвестен.
  final String day;
  final String tid, tournament, kind, level, seg, nation;
  final int place, of;
  final double? points, tes, pcs, ded, base;
  final List<SkateElement> els;

  /// Место и баллы в итоге вида (у обоих сегментов турнира одни и те же).
  final int? totalPlace;
  final double? totalPoints;
  final bool intl;

  /// Протокол лежит в архиве прошлых сезонов.
  final bool archived;

  /// Прокат в командном турнире: тот же сегмент, что личный, — но другой старт (баллы и элементы
  /// свои, место — среди выступавших за команды).
  final bool team;
  const Skate({
    required this.day,
    required this.tid,
    required this.tournament,
    required this.kind,
    required this.level,
    required this.seg,
    required this.place,
    required this.of,
    required this.intl,
    this.nation = '',
    this.points,
    this.tes,
    this.pcs,
    this.ded,
    this.base,
    this.els = const [],
    this.totalPlace,
    this.totalPoints,
    this.archived = false,
    this.team = false,
  });

  /// Короткая программа или ритм-танец (иначе — произвольная).
  bool get short => seg == 'КП' || seg == 'РТ';

  /// Ключ выступления: один турнир, вид, уровень и сегмент — один прокат.
  String get key => '$tid|$kind|$level|$seg${team ? '|team' : ''}';

  /// «2024/25» — сезон начинается в июле.
  String get season {
    final d = DateTime.tryParse(day);
    if (d == null) return '';
    final y = d.month >= 7 ? d.year : d.year - 1;
    return '$y/${two((y + 1) % 100)}';
  }
}

double? _num(Object? v) => v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);

class AthleteHistory {
  final List<Skate> skates;

  /// В протоколах есть полный тёзка: чьи прокаты чьи, не различить — статистику не считаем.
  final bool twins;
  const AthleteHistory(this.skates, {this.twins = false});

  static const empty = AthleteHistory([]);
}

/// CRC-32 (как zlib.crc32 в сборщике): по ней имя попадает в один из 256 файлов истории.
int crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc ^= b;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// Имя файла истории для спортсмена: «3f.json».
String historyFile(String name) => '${(crc32(utf8.encode(norm(name).trim())) % 256).toRadixString(16).padLeft(2, '0')}.json';

String historyUrl(String name) => Uri.parse(dataUrl).resolve('../h/${historyFile(name)}').toString();

/// Файл истории → прокаты одного человека. Нет его в файле — пустая история (не ошибка).
AthleteHistory parseHistory(String body, String name) {
  final j = jsonDecode(body);
  if (j is! Map || j['v'] != 1 || j['a'] is! Map) throw const FormatException('история');
  final tours = j['t'] is Map ? j['t'] as Map : const {};
  final want = norm(name).trim();
  Map? mine;
  for (final e in (j['a'] as Map).entries) {
    if (norm('${e.key}').trim() == want && e.value is Map) mine = e.value as Map;
  }
  if (mine == null) return AthleteHistory.empty;
  final out = <Skate>[];
  for (final r in (mine['r'] as List? ?? const [])) {
    if (r is! Map || r['pl'] is! int) continue;
    final t = tours[r['t']];
    final tour = t is List && t.isNotEmpty ? t : const [];
    out.add(
      Skate(
        day: '${r['d'] ?? ''}',
        tid: '${r['t'] ?? ''}',
        tournament: tour.isEmpty ? '' : '${tour[0]}',
        kind: '${r['k'] ?? ''}',
        level: '${r['l'] ?? ''}',
        seg: '${r['s'] ?? ''}',
        nation: '${r['c'] ?? ''}',
        place: r['pl'] as int,
        of: r['of'] is int ? r['of'] as int : 0,
        points: _num(r['pts']),
        tes: _num(r['tes']),
        pcs: _num(r['pcs']),
        ded: _num(r['ded']),
        base: _num(r['bv']),
        els: [
          for (final e in (r['els'] as List? ?? const []))
            if (e is List && e.length >= 3 && e[0] is String) SkateElement(e[0] as String, '${e[1]}', _num(e[2]) ?? 0),
        ],
        totalPlace: r['tp'] is int ? r['tp'] as int : null,
        totalPoints: _num(r['tpts']),
        intl: tour.length > 1 && tour[1] == 1,
        archived: tour.length > 2 && tour[2] == 1,
        team: r['tm'] == 1,
      ),
    );
  }
  return AthleteHistory(out, twins: mine['x'] == true);
}

/// Клиент — подменяется в тестах.
http.Client historyClient = http.Client();

/// История с сайта; null — не загрузилась (нет связи). Файл один на 1/256 всех спортсменов и
/// меняется раз в сбор — держим в памяти на время работы приложения.
final Map<String, String> _files = {};

Future<AthleteHistory?> loadHistory(String name) async {
  final file = historyFile(name);
  try {
    var body = _files[file];
    if (body == null) {
      final r = await historyClient
          .get(Uri.parse('${historyUrl(name)}?t=${DateTime.now().millisecondsSinceEpoch ~/ 3600000}'))
          .timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) return null;
      body = utf8.decode(r.bodyBytes);
      _files[file] = body;
    }
    return parseHistory(body, name);
  } catch (_) {
    return null;
  }
}

/// То, что приложение знает само: прокаты из расписания на устройстве (в том числе прочитанные с
/// табло минуту назад), где у человека уже есть место и баллы. Элементов здесь нет — только итог.
List<Skate> skatesFromSchedule(Schedule data, String name) {
  final out = <Skate>[];
  for (final s in data.starts) {
    if (s.podium.isEmpty || s.provisional) continue;
    final ranked = s.field.where((o) => o.place != null).length;
    for (final o in s.field) {
      if (o.place == null || !namesInclude([o.name], name)) continue;
      out.add(
        Skate(
          day: s.day,
          tid: s.tid,
          tournament: s.tournament,
          kind: s.kind,
          level: s.level,
          seg: s.seg,
          nation: o.nation,
          place: o.place!,
          of: ranked,
          points: double.tryParse(o.points ?? ''),
          totalPlace: o.overall,
          intl: s.intl,
          team: s.team,
        ),
      );
      break;
    }
  }
  return out;
}

/// История сайта и то, что знает устройство: прокат сайта богаче (в нём элементы) и побеждает;
/// чего на сайте ещё нет — добавляется. По дням, короткая раньше произвольной.
AthleteHistory mergeSkates(AthleteHistory? site, List<Skate> local) {
  final byKey = {for (final s in site?.skates ?? const <Skate>[]) s.key: s};
  for (final s in local) {
    byKey.putIfAbsent(s.key, () => s);
  }
  final all = byKey.values.toList()
    ..sort((a, b) {
      final c = a.day.compareTo(b.day);
      return c != 0 ? c : (a.short ? 0 : 1).compareTo(b.short ? 0 : 1);
    });
  return AthleteHistory(all, twins: site?.twins ?? false);
}

// ------------------------------------------------------------------ счёт

/// Какие баллы показывает график.
enum ScoreKind { short, free, total }

/// Точка графика: прокат и значение.
typedef ScorePoint = ({Skate skate, double value});

/// Ряд баллов по времени. Сумма — баллы итога вида, по разу на турнир (берём у произвольной).
List<ScorePoint> scoreSeries(List<Skate> skates, ScoreKind kind) {
  final out = <ScorePoint>[];
  for (final s in skates) {
    if (kind == ScoreKind.total) {
      if (!s.short && s.totalPoints != null) out.add((skate: s, value: s.totalPoints!));
    } else if (s.short == (kind == ScoreKind.short) && s.points != null) {
      out.add((skate: s, value: s.points!));
    }
  }
  return out;
}

/// Один прыжок внутри элемента: «3Lz» и отметки судей на нём.
typedef JumpToken = ({String jump, String marks, bool thrown});

final _jumpRe = RegExp(r'^(\d)(Lz|Lo|A|T|S|F)(Th)?([<!eq*]*)');

/// Прыжки элемента: «3Lz!+3T<» → 3Lz (!), 3T (<). Ойлер, «SEQ», «REP» и не прыжки пропускаются;
/// выбросы пар («3LoTh») — с пометкой thrown.
List<JumpToken> jumpsOf(String code) {
  final out = <JumpToken>[];
  for (final part in code.split('+')) {
    final m = _jumpRe.firstMatch(part.trim());
    if (m == null) continue;
    // «3Tw4» — подкрутка, а не тулуп: за буквой прыжка не должно идти продолжение кода
    final rest = part.trim().substring(m.end);
    if (rest.isNotEmpty && !RegExp(r'^[<!eq*VBx]*$').hasMatch(rest)) continue;
    out.add((jump: '${m.group(1)}${m.group(2)}${m.group(3) ?? ''}', marks: m.group(4) ?? '', thrown: m.group(3) != null));
  }
  return out;
}

/// Сколько раз прыжок исполнен и как.
class JumpStat {
  final String jump;
  int done = 0, clean = 0, under = 0, edge = 0;

  /// Сольные исполнения (не в каскаде) и сумма их GOE — для средней оценки.
  int solo = 0;
  double soloGoe = 0;
  JumpStat(this.jump);

  double? get avgGoe => solo == 0 ? null : soloGoe / solo;
}

const _jumpOrder = ['A', 'Lz', 'F', 'Lo', 'S', 'T'];

/// Прыжки по убыванию сложности: четверные раньше тройных, внутри — аксель, лутц, флип…
/// Одинарные и двойные (кроме акселя) не считаем: это либо связки, либо сорванные прыжки,
/// и про «стабильность» они ничего не говорят.
List<JumpStat> jumpStats(List<Skate> skates) {
  final by = <String, JumpStat>{};
  for (final s in skates) {
    for (final e in s.els) {
      final tokens = jumpsOf(e.code);
      for (final t in tokens) {
        final turns = int.parse(t.jump[0]);
        if (turns < 2 || (turns == 2 && !t.jump.startsWith('2A'))) continue;
        final st = by.putIfAbsent(t.jump, () => JumpStat(t.jump));
        st.done++;
        final under = t.marks.contains('<') || t.marks.contains('q');
        final edge = t.marks.contains('e') || t.marks.contains('!');
        if (under) st.under++;
        if (edge) st.edge++;
        if (t.marks.isEmpty && !e.fall && e.goe >= 0) st.clean++;
        if (tokens.length == 1) {
          st.solo++;
          st.soloGoe += e.goe;
        }
      }
    }
  }
  int rank(String j) {
    final type = j.substring(1).replaceAll('Th', '');
    return -int.parse(j[0]) * 100 + _jumpOrder.indexOf(type) + (j.endsWith('Th') ? 50 : 0);
  }

  return by.values.toList()..sort((a, b) => rank(a.jump).compareTo(rank(b.jump)));
}

/// Падений на элементах и в скольких прокатах (с разбором элементов).
({int falls, int skates, int detailed}) fallStats(List<Skate> skates) {
  var falls = 0, with_ = 0, detailed = 0;
  for (final s in skates) {
    if (s.els.isEmpty) continue;
    detailed++;
    final n = s.els.where((e) => e.fall).length;
    falls += n;
    if (n > 0) with_++;
  }
  return (falls: falls, skates: with_, detailed: detailed);
}

/// Уровни элементов одной группы: сколько исполнено и сколько из них на четвёртый уровень.
class LevelStat {
  final String group;
  int done = 0, top = 0;
  LevelStat(this.group);
}

final _levelRe = RegExp(r'^(\d?)([A-Za-z]+?)(B|[1-4])[!<>*V]*$');

String? _levelGroup(String lead, String name) {
  if (name.startsWith('Ch')) return null; // хореографические — без уровней
  if (name.contains('Sp')) return 'Вращения';
  if (name.endsWith('Tw') && lead.isNotEmpty) return 'Подкрутка';
  if (name.contains('Tw')) return 'Твизлы';
  if (name.contains('Li')) return 'Поддержки';
  if (name.contains('Ds')) return 'Тодесы';
  if (name.contains('St') || name.contains('Sq')) return 'Дорожки шагов';
  return null;
}

/// Уровни вращений, дорожек, твизлов, поддержек, тодесов и подкрутки — по группам, в этом порядке.
List<LevelStat> levelStats(List<Skate> skates) {
  const order = ['Вращения', 'Дорожки шагов', 'Твизлы', 'Поддержки', 'Подкрутка', 'Тодесы'];
  final by = <String, LevelStat>{};
  for (final s in skates) {
    for (final e in s.els) {
      for (final part in e.code.split('+')) {
        final m = _levelRe.firstMatch(part.trim());
        if (m == null) continue;
        final g = _levelGroup(m.group(1)!, m.group(2)!);
        if (g == null) continue;
        final st = by.putIfAbsent(g, () => LevelStat(g));
        st.done++;
        if (m.group(3) == '4') st.top++;
      }
    }
  }
  return [for (final g in order) ?by[g]];
}
