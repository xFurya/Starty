// Профиль спортсмена: справка, титулы, примечательное, личные рекорды, музыка и результаты. Файл
// профиля (site/p/<ключ>.json) собирает сервер из биографий ISU и картотеки ФФККР (scraper/profiles.py),
// примечательное — мировые рекорды из статистики ISU и архив судейских протоколов (scraper/feats.py);
// чего в источниках нет, того нет и здесь — ни строки с догадкой.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'countries.dart';
import 'data.dart';
import 'flags.dart';
import 'palette.dart';
import 'protocol.dart' show openLink;
import 'settings.dart' show FeedbackAbout, ReportLink, openBilling;
import 'sheets.dart' show showStart, showSwipeSheet;
import 'state.dart';
import 'stats.dart';
import 'ui.dart';
import 'views.dart' show PlacingName, dateRange;

// ------------------------------------------------------------------ данные

class ProfileWho {
  final String name, born, place, club, rank, region;
  final int? height, since;
  final List<String> former;
  const ProfileWho({
    required this.name,
    this.born = '',
    this.place = '',
    this.club = '',
    this.rank = '',
    this.region = '',
    this.height,
    this.since,
    this.former = const [],
  });

  factory ProfileWho.fromJson(Map j) => ProfileWho(
    name: _s(j['n']),
    born: _s(j['born']),
    place: _s(j['place']),
    club: _s(j['club']),
    rank: _s(j['rank']),
    region: _s(j['region']),
    height: j['h'] is int ? j['h'] as int : null,
    since: j['since'] is int ? j['since'] as int : null,
    former: _list(j['former']),
  );
}

/// Оценка: сумма или сегмент (s: total, sp, fs), баллы, дата и турнир.
class ProfileScore {
  final String seg, points, date, event;
  const ProfileScore(this.seg, this.points, this.date, this.event);
  factory ProfileScore.fromJson(Map j) => ProfileScore(_s(j['s']), _s(j['pts']), _s(j['d']), _s(j['ev']));
}

/// Примечательное: мировой рекорд или первое в истории. [points] — только у рекорда; [url] —
/// источник, по нему строка открывается во встроенном браузере.
class ProfileFeat {
  final String title, event, date, points, source, url;
  const ProfileFeat(this.title, this.event, {this.date = '', this.points = '', this.source = '', this.url = ''});
  factory ProfileFeat.fromJson(Map j) =>
      ProfileFeat(_s(j['t']), _s(j['ev']), date: _s(j['d']), points: _s(j['pts']), source: _s(j['src']), url: _s(j['u']));
}

/// Сборная на сезон — по официальному списку федерации (ФФККР, JSF, Skate Canada): страна, состав
/// («основной состав», «резерв NextGen», «состав A»), сезон «2026/27». Списка нет или сезон кончился —
/// сервер строки не присылает.
class ProfileTeam {
  final String country, squad, season;
  const ProfileTeam(this.country, this.squad, this.season);

  /// «Россия, основной состав».
  String get line => [country, squad].where((x) => x.isNotEmpty).join(', ');

  /// «Сезон 2026/27» — приглушённо под строкой; сезона нет — пусто.
  String get note => season.isEmpty ? '' : 'Сезон $season';
}

/// Пьедестал главного турнира.
class ProfileTitle {
  final String event, kind, season;
  final int place;
  const ProfileTitle(this.event, this.kind, this.place, this.season);
}

/// Результат на турнире: место числом или как у ISU («WD»).
class ProfileResult {
  final String event, kind, place;
  const ProfileResult(this.event, this.kind, this.place);
  int? get placeNumber => int.tryParse(place);
}

class ProfileGroup {
  final String name;
  final List<ProfileResult> rows;
  const ProfileGroup(this.name, this.rows);
}

/// Старт сезона из картотеки ФФККР: место как там написано («8 (МС)»).
class ProfileStart {
  final String season, event, place;
  const ProfileStart(this.season, this.event, this.place);
}

class Profile {
  final String name;
  final List<ProfileWho> who;
  final List<String> coach, choreo, formerCoach;
  final String musicSeason;
  final List<String> musicShort, musicFree;
  final List<ProfileScore> best, seasonBest;
  final List<ProfileTitle> titles;
  final List<ProfileFeat> feats;
  final ProfileTeam? team;
  final List<ProfileGroup> results;
  final List<ProfileStart> season;
  final List<String> sources;

  /// Когда сервер последний раз сверил справку с источниками: «2026-11-05».
  final String checked;

  const Profile({
    required this.name,
    this.who = const [],
    this.coach = const [],
    this.choreo = const [],
    this.formerCoach = const [],
    this.musicSeason = '',
    this.musicShort = const [],
    this.musicFree = const [],
    this.best = const [],
    this.seasonBest = const [],
    this.titles = const [],
    this.feats = const [],
    this.team,
    this.results = const [],
    this.season = const [],
    this.sources = const [],
    this.checked = '',
  });

  factory Profile.fromJson(Map j) {
    final music = j['music'] is Map ? j['music'] as Map : const {};
    final team = j['team'] is Map ? j['team'] as Map : const {};
    List<Map> maps(Object? v) => [
      for (final x in (v is List ? v : const []))
        if (x is Map) x,
    ];
    return Profile(
      name: _s(j['n']),
      who: [for (final w in maps(j['who'])) ProfileWho.fromJson(w)],
      coach: _list(j['coach']),
      choreo: _list(j['choreo']),
      formerCoach: _list(j['fcoach']),
      musicSeason: _s(music['season']),
      musicShort: _list(music['sp']),
      musicFree: _list(music['fs']),
      best: [for (final x in maps(j['pb'])) ProfileScore.fromJson(x)],
      seasonBest: [for (final x in maps(j['sb'])) ProfileScore.fromJson(x)],
      titles: [
        for (final x in maps(j['titles']))
          if (x['pl'] is int) ProfileTitle(_s(x['ev']), _s(x['k']), x['pl'] as int, _s(x['y'])),
      ],
      feats: [
        for (final x in maps(j['feats']))
          if (_s(x['t']).isNotEmpty) ProfileFeat.fromJson(x),
      ],
      team: _s(team['c']).isEmpty || _s(team['t']).isEmpty
          ? null
          : ProfileTeam(_s(team['c']), _s(team['t']), _s(team['y'])),
      results: [
        for (final g in maps(j['res']))
          ProfileGroup(_s(g['g']), [for (final r in maps(g['r'])) ProfileResult(_s(r['ev']), _s(r['k']), _s(r['pl']))]),
      ],
      season: [for (final x in maps(j['season'])) ProfileStart(_s(x['s']), _s(x['ev']), _s(x['pl']))],
      sources: _list(j['src']),
      checked: _s(j['at']),
    );
  }

  /// Танцоры: сегменты называются ритм-танцем и произвольным танцем.
  bool get dance =>
      results.any((g) => g.rows.any((r) => r.kind.toLowerCase() == 'd')) ||
      titles.any((t) => t.kind.toLowerCase() == 'd');
}

/// Старты в два раздела: «Внутренние» — национальные чемпионаты (у любой страны), «Международные» —
/// всё остальное: серии ISU и приглашённые турниры. Сервер уже присылает эти два раздела
/// (scraper/profiles.py, two_groups); прежние файлы — по группам ISU, их сводим здесь так же.
/// Внутри раздела — новые турниры первыми; при равном годе — как пришло.
List<ProfileGroup> twoResultGroups(List<ProfileGroup> groups) {
  const domestic = {'Внутренние', 'Национальные чемпионаты'};
  final intl = <(int, ProfileResult)>[], home = <(int, ProfileResult)>[];
  var n = 0;
  for (final g in groups) {
    for (final r in g.rows) {
      (domestic.contains(g.name) ? home : intl).add((n++, r));
    }
  }
  int year(ProfileResult r) => int.tryParse(RegExp(r'(\d{4})(?:/\d\d)?$').firstMatch(r.event)?.group(1) ?? '') ?? 0;
  List<ProfileResult> newestFirst(List<(int, ProfileResult)> xs) {
    final sorted = [...xs]..sort((a, b) {
      final c = year(b.$2).compareTo(year(a.$2));
      return c != 0 ? c : a.$1.compareTo(b.$1);
    });
    return [for (final x in sorted) x.$2];
  }

  return [
    if (intl.isNotEmpty) ProfileGroup('Международные', newestFirst(intl)),
    if (home.isNotEmpty) ProfileGroup('Внутренние', newestFirst(home)),
  ];
}

String _s(Object? v) => v == null ? '' : '$v'.trim();
List<String> _list(Object? v) => [
  for (final x in (v is List ? v : const []))
    if (_s(x).isNotEmpty) _s(x),
];

// ------------------------------------------------------------------ загрузка

String profileUrl(String key) => Uri.parse(dataUrl).resolve('../p/$key.json').toString();

final _loaded = <String, Profile>{};

/// Загрузка профиля по ключу: null — файла нет (404), ошибка сети — исключение. В памяти держится
/// до конца работы приложения. В тестах подменяется.
Future<Profile?> Function(String key) profileLoader = _load;

Future<Profile?> _load(String key) async {
  final hit = _loaded[key];
  if (hit != null) return hit;
  final r = await http.get(Uri.parse(profileUrl(key))).timeout(const Duration(seconds: 20));
  if (r.statusCode == 404) return null;
  if (r.statusCode != 200) throw http.ClientException('HTTP ${r.statusCode}');
  final p = Profile.fromJson(jsonDecode(utf8.decode(r.bodyBytes)) as Map);
  _loaded[key] = p;
  return p;
}

// ------------------------------------------------------------------ слова

const _monthsGen = [
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

/// «2007-06-05» → «5 июня 2007»; непонятное — как есть.
String profileDate(String iso) {
  final m = RegExp(r'^(\d{4})-(\d\d)-(\d\d)$').firstMatch(iso);
  if (m == null) return iso;
  return '${int.parse(m[3]!)}$nb${_monthsGen[int.parse(m[2]!) - 1]} ${m[1]}';
}

/// Полных лет на [at]; дата непонятна — null.
int? ageOn(String born, DateTime at) {
  final b = DateTime.tryParse(born);
  if (b == null || born.length != 10) return null;
  var a = at.year - b.year;
  if (at.month < b.month || (at.month == b.month && at.day < b.day)) a--;
  return a < 0 ? null : a;
}

String yearsWord(int n) => '$n$nb${plural(n, 'год', 'года', 'лет')}';

String segLabel(String seg, {required bool dance}) => switch (seg) {
  'total' => 'Сумма',
  'sp' => dance ? 'Ритм-танец' : 'Короткая программа',
  'fs' => dance ? 'Произвольный танец' : 'Произвольная программа',
  _ => seg,
};

/// Сезон по дате оценки: с июля — новый. «2026-10-03» → «2026/27».
String seasonOfDate(String iso) {
  final d = DateTime.tryParse(iso);
  if (d == null) return '';
  final y = d.month >= 7 ? d.year : d.year - 1;
  return '$y/${((y + 1) % 100).toString().padLeft(2, '0')}';
}

/// «8 (МС)» → (8, «МС»); без числа впереди — (null, как есть).
(int?, String) splitPlace(String raw) {
  final m = RegExp(r'^(\d+)\s*(?:\((.*)\))?\s*$').firstMatch(raw.trim());
  if (m == null) return (null, raw.trim());
  return (int.parse(m[1]!), (m[2] ?? '').trim());
}

/// Подпись вида у строки турнира — только когда вид не ясен: у человека несколько дисциплин
/// ([multi]) или юниорский старт, в названии которого юниоры не названы.
String kindNote(String event, String kind, {required bool multi}) {
  final line = kindsLine(kind);
  if (line.isEmpty) return '';
  final junior = kind != kind.toLowerCase();
  final said = RegExp(r'юниор|первенство|^jgp\b', caseSensitive: false).hasMatch(event);
  if (!multi && (!junior || said)) return '';
  return cap(line);
}

String _sourcesLine(List<String> src, String checked) {
  final who = src.isEmpty
      ? ''
      : src.length == 1
      ? src.first
      : '${src.sublist(0, src.length - 1).join(', ')} и ${src.last}';
  final when = checked.isEmpty ? '' : ' на ${profileDate(checked)}';
  return who.isEmpty ? '' : 'По данным $who$when';
}

// ------------------------------------------------------------------ лист

/// Профиль спортсмена листом поверх текущего экрана. [name] — как в данных (пара — одной записью).
void showProfile(BuildContext context, String name, Schedule? data) {
  showSwipeSheet<void>(context, (c, scroll) => ProfileSheet(name: name, data: data, scrollController: scroll), top: .92);
}

/// Состояние приложения: с ним в шапке профиля есть «Отслеживать». Ставит приложение при запуске;
/// без него (лист отдельно от приложения) кнопки нет.
AppState? profileState;

/// Отслеживаемые после нажатия в профиле. Не было — добавляем, как в справочнике. Был — убираем
/// его запись и записи партнёров, по которым пара считалась отслеживаемой: иначе кнопка
/// осталась бы нажатой.
Set<String> followToggled(Follow f, String name) {
  if (!f.has(name)) return {...f.names, name};
  final keys = {norm(name), for (final m in name.split(' / ')) norm(m.trim())};
  return {for (final n in f.names) if (!keys.contains(norm(n))) n};
}

/// «Отслеживать» в шапке профиля: одно нажатие вместо настроек, сохраняется сразу.
class FollowPill extends StatelessWidget {
  final AppState state;

  /// Имя как в справочнике (пара — одной записью).
  final String name;
  const FollowPill({super.key, required this.state, required this.name});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) {
      final p = Palette.of(context);
      final f = state.follow;
      final on = f.has(name);
      final fg = on ? p.onAccent : p.ink;
      void flip() => unawaited(
        state.setFollow(followToggled(f, name), russians: f.russians, belarusians: f.belarusians),
      );
      return Semantics(
        button: true,
        // состояние — отдельно от названия: «Отслеживать, включено», а не два раза об одном
        toggled: on,
        label: 'Отслеживать',
        excludeSemantics: true,
        // видимая кнопка 40 pt, зона нажатия 48
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: flip,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Material(
              color: on ? p.accent : p.plate,
              shape: StadiumBorder(side: BorderSide(color: on ? p.accent : p.control, width: 1.2)),
              clipBehavior: Clip.antiAlias,
              // InkWell — ради клавиатуры на компьютере и в браузере: фокус и Enter
              child: InkWell(
                onTap: flip,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 40),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 15, 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(on ? CupertinoIcons.checkmark_alt : CupertinoIcons.plus, size: 17, color: on ? fg : p.accent),
                        const SizedBox(width: 6),
                        Text(
                          // пара и танцы — двое: «отслеживаются»
                          on ? (name.contains(' / ') ? 'Отслеживаются' : 'Отслеживается') : 'Отслеживать',
                          maxLines: 1,
                          style: TextStyle(fontSize: 14.5, height: 1.2, fontWeight: FontWeight.w600, color: fg),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// Спортсмен, которого можно открыть: он есть в справочнике сборщика.
bool hasProfile(Schedule? data, String name) => data?.personOf(name) != null;

/// Строка или фото спортсмена, по нажатию — его профиль. Человека нет в справочнике — как было,
/// без пустого нажатия. Рябь рисуется поверх плашки, а не под её заливкой.
class ProfileTap extends StatelessWidget {
  final String name;
  final Schedule? data;
  final Widget child;
  final BorderRadius? radius;

  /// Что читать вслух: по умолчанию — имя и «профиль».
  final String? label;
  const ProfileTap({super.key, required this.name, required this.data, required this.child, this.radius, this.label});

  @override
  Widget build(BuildContext context) {
    if (!hasProfile(data, name)) return child;
    return Semantics(
      button: true,
      label: label,
      hint: 'открыть профиль',
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(onTap: () => showProfile(context, name, data), borderRadius: radius, child: child),
      ),
    );
  }
}

class ProfileSheet extends StatefulWidget {
  final String name;
  final Schedule? data;
  final ScrollController? scrollController;
  const ProfileSheet({super.key, required this.name, required this.data, this.scrollController});
  @override
  State<ProfileSheet> createState() => _ProfileSheetState();
}

class _ProfileSheetState extends State<ProfileSheet> {
  Future<Profile?>? _future;

  Person? get _person => widget.data?.personOf(widget.name);

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    final key = _person?.profile;
    _future = key == null ? null : profileLoader(key);
  }

  /// Где он выступает дальше — по заявкам в расписании; нигде не заявлен — раздела нет.
  Widget? get _ahead {
    final data = widget.data, person = _person;
    if (data == null || person == null) return null;
    final a = aheadOf(data, person.name, now());
    return a.starts.isEmpty && a.tours.isEmpty ? null : _Ahead(starts: a.starts, tours: a.tours);
  }

  /// «Статистика»: с подпиской — числа; без неё — строка о том, что это в подписке; а если подписка
  /// в этой сборке не продаётся, раздела нет вовсе — показывать закрытое, которое нельзя открыть, незачем.
  Widget? _stats(BuildContext context) {
    final st = profileState;
    if (st == null) return null;
    final open = st.billing.perksAt(now());
    if (!open && !st.billing.visible) return null;
    return StatsSection(
      key: ValueKey('stats-${widget.name}-$open'),
      name: widget.name,
      data: widget.data,
      open: open,
      onSubscribe: () => openBilling(context, st),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .92),
      child: SheetScroll(
        controller: widget.scrollController,
        child: FutureBuilder<Profile?>(
          future: _future,
          builder: (context, snap) {
            final pr = snap.data;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children:
                  [
                        _ProfileHead(name: widget.name, person: _person, data: widget.data, profile: pr),
                        // из расписания, а не из справки: видно сразу и у тех, о ком справки нет
                        if (_ahead case final a?) _section(context, 'Ближайшие старты', a),
                        if (_future == null)
                          _section(context, 'Справка', const _Note('Справки о спортсмене пока нет'))
                        else if (snap.connectionState != ConnectionState.done)
                          _section(context, 'Справка', const _Loading())
                        else if (snap.hasError)
                          _section(
                            context,
                            'Справка',
                            _Note(
                              'Справка не загрузилась: нет связи с сервером',
                              action: 'Повторить',
                              onAction: () => setState(_start),
                            ),
                          )
                        else if (pr == null)
                          _section(context, 'Справка', const _Note('Справки о спортсмене пока нет'))
                        else
                          ..._body(context, pr),
                        // подписка: баллы по стартам, прыжки, уровни — по протоколам, не по справке
                        if (_stats(context) case final st?) _section(context, 'Статистика', st),
                        SizedBox(height: 26 + MediaQuery.paddingOf(context).bottom),
                      ]
                      .map(
                        (w) => w is SizedBox
                            ? w
                            : DefaultTextStyle.merge(
                                style: TextStyle(color: p.ink),
                                child: w,
                              ),
                      )
                      .toList(),
            );
          },
        ),
      ),
    );
  }

  List<Widget> _body(BuildContext context, Profile pr) {
    final p = Palette.of(context);
    final facts = _facts(pr);
    // дисциплины без учёта возраста: больше одной — вид подписан у каждой строки
    final multi =
        ({
          for (final g in pr.results)
            for (final r in g.rows) r.kind.toLowerCase(),
          for (final t in pr.titles) t.kind.toLowerCase(),
        }..remove('')).length >
        1;
    final sbSeason = pr.seasonBest.isEmpty ? '' : seasonOfDate(pr.seasonBest.first.date);
    final src = _sourcesLine(pr.sources, pr.checked);
    return [
      if (pr.titles.isNotEmpty)
        _section(
          context,
          'Титулы',
          _MedalList(
            strong: true,
            rows: [
              for (final t in pr.titles)
                (place: t.place, mark: '${t.place}', event: t.event, note: kindNote(t.event, t.kind, multi: multi)),
            ],
          ),
        ),
      if (pr.feats.isNotEmpty) _section(context, 'Примечательное', _Feats(list: pr.feats)),
      if (pr.best.isNotEmpty) _section(context, 'Личные рекорды', _Scores(list: pr.best, dance: pr.dance)),
      if (pr.seasonBest.isNotEmpty)
        _section(
          context,
          sbSeason.isEmpty ? 'Лучшее в сезоне' : 'Лучшее в сезоне $sbSeason',
          _Scores(list: pr.seasonBest, dance: pr.dance),
        ),
      if (facts.isNotEmpty) _section(context, 'Справка', Plate(child: Column(children: facts))),
      if (pr.musicShort.isNotEmpty || pr.musicFree.isNotEmpty)
        _section(
          context,
          pr.musicSeason.isEmpty ? 'Музыка' : 'Музыка сезона ${pr.musicSeason}',
          Plate(
            child: Column(
              children: [
                if (pr.musicShort.isNotEmpty)
                  _Music(
                    label: segLabel('sp', dance: pr.dance),
                    lines: pr.musicShort,
                  ),
                if (pr.musicShort.isNotEmpty && pr.musicFree.isNotEmpty) const Hairline(),
                if (pr.musicFree.isNotEmpty)
                  _Music(
                    label: segLabel('fs', dance: pr.dance),
                    lines: pr.musicFree,
                  ),
              ],
            ),
          ),
        ),
      if (pr.season.isNotEmpty)
        _section(
          context,
          pr.season.first.season.isEmpty ? 'Старты сезона' : 'Старты сезона ${pr.season.first.season}',
          _Season(list: pr.season),
        ),
      for (final (i, g) in twoResultGroups(pr.results).indexed)
        _section(
          context,
          g.name,
          _MedalList(
            rows: [
              for (final r in g.rows)
                (place: r.placeNumber, mark: r.place, event: r.event, note: kindNote(r.event, r.kind, multi: multi)),
            ],
          ),
          top: i == 0 ? 24 : 18,
        ),
      if (pr.titles.isEmpty &&
          pr.feats.isEmpty &&
          pr.best.isEmpty &&
          facts.isEmpty &&
          pr.results.isEmpty &&
          pr.season.isEmpty)
        _section(context, 'Справка', const _Note('Справки о спортсмене пока нет')),
      if (src.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 0),
          child: Text(src, style: TextStyle(fontSize: 13, color: p.ink2, height: 1.35)),
        ),
      // неверный тренер, фото, звание — сообщение сразу знает, о ком
      ReportLink(
        about: FeedbackAbout(
          id: 'profile:${widget.name}',
          icon: CupertinoIcons.person,
          title: widget.name,
          subtitle: 'Профиль спортсмена',
        ),
        padding: EdgeInsets.fromLTRB(12, src.isNotEmpty ? 6 : 14, 12, 0),
      ),
    ];
  }

  /// Строки справки. У пары — по партнёру (имя подзаголовком), тренеры общие — ниже.
  List<Widget> _facts(Profile pr) {
    final out = <Widget>[];
    void add(Widget w) {
      if (out.isNotEmpty) out.add(const Hairline());
      out.add(w);
    }

    final pair = pr.who.length > 1;
    final today = now();
    // у пары сборная одна на двоих (сервер даёт её, только если в списке оба партнёра) — над справкой
    // партнёров, чтобы не читалась как строка второго из них
    if (pair && pr.team != null) out.add(_Fact(label: 'Сборная', lines: [pr.team!.line], note: pr.team!.note));
    for (final w in pr.who) {
      final rows = <Widget>[];
      void row(String label, String value) {
        if (value.isEmpty) return;
        if (rows.isNotEmpty) rows.add(const Hairline());
        rows.add(_Fact(label: label, lines: [value]));
      }

      final age = ageOn(w.born, today);
      row('Дата рождения', w.born.isEmpty ? '' : '${profileDate(w.born)}${age == null ? '' : ', ${yearsWord(age)}'}');
      row('Место рождения', w.place);
      row('Рост', w.height == null ? '' : '${w.height}$nbсм');
      row('Катается с', w.since == null ? '' : '${w.since}$nbгода');
      row('Звание', w.rank);
      if (!pair && pr.team != null) {
        if (rows.isNotEmpty) rows.add(const Hairline());
        rows.add(_Fact(label: 'Сборная', lines: [pr.team!.line], note: pr.team!.note));
      }
      row('Регион', w.region);
      row('Клуб', w.club);
      row(w.former.length > 1 ? 'Прежние партнёры' : 'Прежний партнёр', w.former.join(', '));
      if (rows.isEmpty) continue;
      if (pair) {
        if (out.isNotEmpty) out.add(const Hairline());
        out.add(_WhoHead(w.name));
      } else if (out.isNotEmpty) {
        out.add(const Hairline());
      }
      out.addAll(rows);
    }
    if (pr.coach.isNotEmpty) add(_Fact(label: pr.coach.length > 1 ? 'Тренеры' : 'Тренер', lines: pr.coach));
    if (pr.choreo.isNotEmpty) add(_Fact(label: pr.choreo.length > 1 ? 'Хореографы' : 'Хореограф', lines: pr.choreo));
    if (pr.formerCoach.isNotEmpty) add(_Fact(label: 'Прежние тренеры', lines: pr.formerCoach));
    return out;
  }

  /// Раздел листа: подпись и плашка.
  Widget _section(BuildContext context, String label, Widget child, {double top = 24}) => Padding(
    padding: EdgeInsets.only(top: top),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Eyebrow(label, padding: const EdgeInsets.fromLTRB(22, 0, 22, 10)),
        child,
      ],
    ),
  );
}

/// Ближайшие старты спортсмена: когда, турнир, вид и программа. Строка старта открывает его
/// карточку (внутри приложения); у турнира без расписания открывать нечего — он строкой без нажатия.
class _Ahead extends StatefulWidget {
  final List<Start> starts;
  final List<Upcoming> tours;
  const _Ahead({required this.starts, required this.tours});
  @override
  State<_Ahead> createState() => _AheadState();
}

class _AheadState extends State<_Ahead> {
  static const _first = 4;
  bool all = false;

  /// «Сегодня, 14:00», «Завтра, 14:00», «12 ноября, 14:00» — по Москве, как во всём приложении.
  static String _when(Start s, DateTime t) {
    if (s.day == dayKey(t)) return 'Сегодня, ${hm(s.t0)}';
    if (s.day == dayKey(t.add(const Duration(days: 1)))) return 'Завтра, ${hm(s.t0)}';
    return dateTime(s.t0);
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final st = profileState;
    final t = now();
    final rows = <Widget>[
      for (final s in widget.starts)
        _AheadRow(
          when: _when(s, t),
          title: s.tournament,
          note: [kindLabel(s.kind, {s.level}), ?segNames[s.seg]].join(', '),
          onTap: st == null ? null : () => showStart(context, s, st),
        ),
      for (final u in widget.tours)
        _AheadRow(when: dateRange(u.start, u.end), title: u.name, note: 'Расписания пока нет'),
    ];
    final list = all || rows.length <= _first + 1 ? rows : rows.sublist(0, _first);
    final more = rows.length - list.length;
    return Plate(
      child: Column(
        children: [
          for (var i = 0; i < list.length; i++) ...[
            if (i > 0) const Hairline(),
            list[i],
          ],
          if (more > 0) ...[
            const Hairline(),
            Semantics(
              button: true,
              child: InkWell(
                onTap: () => setState(() => all = true),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Ещё $more',
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: p.accent),
                          ),
                        ),
                        Icon(CupertinoIcons.chevron_down, size: 16, color: p.accent),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _AheadRow extends StatelessWidget {
  final String when, title, note;
  final VoidCallback? onTap;
  const _AheadRow({required this.when, required this.title, required this.note, this.onTap});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    when,
                    style: TextStyle(fontSize: 13, height: 1.3, fontWeight: FontWeight.w700, color: p.accent, fontFeatures: tnum),
                  ),
                  const SizedBox(height: 2),
                  Text(title, style: TextStyle(fontSize: 15.5, height: 1.3, fontWeight: FontWeight.w600, color: p.ink)),
                  if (note.isNotEmpty)
                    Text(note, style: TextStyle(fontSize: 13.5, height: 1.35, color: p.ink2)),
                ],
              ),
            ),
            if (onTap != null) ...[
              const SizedBox(width: 10),
              Icon(CupertinoIcons.chevron_right, size: 16, color: p.control),
            ],
          ],
        ),
      ),
    );
    if (onTap == null) return row;
    return Semantics(
      button: true,
      hint: 'открыть старт',
      child: InkWell(onTap: onTap, child: row),
    );
  }
}

/// Шапка: лёд, крупное фото, виды, имя антиквой, страна и возраст.
class _ProfileHead extends StatelessWidget {
  final String name;
  final Person? person;
  final Schedule? data;
  final Profile? profile;
  const _ProfileHead({required this.name, required this.person, required this.data, required this.profile});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final shown = displayName(person?.name ?? name);
    final parts = shown.split(' / ').map((x) => x.trim()).toList();
    final kinds = kindsLineOf(person?.kinds ?? '', was: person?.was ?? '', wasSeason: person?.wasSeason ?? '');
    final nation = person?.nation ?? '';
    final who = profile?.who ?? const <ProfileWho>[];
    // возраст — у одиночника и только по дате рождения из справки
    final age = who.length == 1 ? ageOn(who.first.born, now()) : null;
    final rank = who.length == 1 ? who.first.rank : '';
    final narrow = MediaQuery.sizeOf(context).width < 360;
    final short = isShortWindow(context);
    final avatar = Avatar(name: person?.name ?? name, data: data, size: short ? 72 : (narrow ? 76 : 88), ring: p.plate, ringWidth: 3);
    // отслеживать можно того, кто есть в справочнике: имя — как там, по нему его узнают старты
    final st = profileState;
    final follow = st == null || person == null
        ? null
        : Flexible(
            child: FittedBox(fit: BoxFit.scaleDown, child: FollowPill(state: st, name: person!.name)),
          );
    final details = <Widget>[
      if (kinds.isNotEmpty)
        Eyebrow(kinds, color: p.accent, maxLines: 2, padding: const EdgeInsets.only(bottom: 8)),
      // пара — по партнёру на строку, имя целиком, без обрезки
      Semantics(
        header: true,
        child: Text(
          [for (var i = 0; i < parts.length; i++) i < parts.length - 1 ? '${parts[i]} /' : parts[i]]
              .join('\n'),
          style: display(p, parts.length > 1 ? 28 : 34),
        ),
      ),
      if (nation.isNotEmpty || age != null || rank.isNotEmpty) ...[
        const SizedBox(height: 10),
        Wrap(
          spacing: 12,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (nation.isNotEmpty) NationTag(nation, style: PlacingName.codeStyle(p, 15)),
            if (age != null)
              Text(
                yearsWord(age),
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: p.ink2),
              ),
            if (rank.isNotEmpty) Tag(rank, strong: false),
          ],
        ),
      ],
    ];
    return Stack(
      children: [
        Positioned.fill(child: IceBackdrop(fadeTo: p.sheet, fadeStart: .3, sparkles: -1)),
        const Positioned(top: 0, left: 0, right: 0, child: SheetSparkles()),
        SizedBox(
          width: double.infinity,
          child: Padding(
            padding: EdgeInsets.fromLTRB(22, short ? 32 : 40, 22, 4),
            // телефон боком — фото слева от имени: высоты мало
            child: short
                ? Row(
                    children: [
                      avatar,
                      const SizedBox(width: 18),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: details)),
                      if (follow != null) ...[const SizedBox(width: 12), follow],
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // кнопка — на уровне низа фото, у правого края
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [avatar, if (follow != null) ...[const SizedBox(width: 12), follow]],
                      ),
                      const SizedBox(height: 16),
                      ...details,
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

/// Строка справки: подпись слева, значение справа (у тренеров — по человеку на строку).
class _Fact extends StatelessWidget {
  final String label;
  final List<String> lines;

  /// Пояснение под значением, приглушённо: «Сезон 2026/27».
  final String note;
  const _Fact({required this.label, required this.lines, this.note = ''});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return LayoutBuilder(
      builder: (context, c) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 11, 16, 11),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            SizedBox(
              width: (c.maxWidth - 32 - 12) * .4,
              child: Text(label, style: TextStyle(fontSize: 14, color: p.ink2, height: 1.35)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final l in lines)
                    Text(
                      l,
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: p.ink, height: 1.35),
                    ),
                  if (note.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(note, style: TextStyle(fontSize: 14, color: p.ink2, height: 1.35)),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Музыка программы: подпись мелкими прописными, ниже — произведения по строке.
class _Music extends StatelessWidget {
  final String label;
  final List<String> lines;
  const _Music({required this.label, required this.lines});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: SizedBox(
        width: double.infinity,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Eyebrow(label),
            for (final l in lines)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  l,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: p.ink, height: 1.35),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Имя партнёра над его строками справки.
class _WhoHead extends StatelessWidget {
  final String name;
  const _WhoHead(this.name);
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: SizedBox(
        width: double.infinity,
        child: Text(displayName(name), style: display(p, 20)),
      ),
    );
  }
}

/// Строка списка мест: место, турнир и, если нужно, вид.
typedef _Placed = ({int? place, String mark, String event, String note});

/// Список мест (титулы, результаты): медаль или номер места, турнир; длинный — первые шесть
/// и «Ещё N», чтобы лист не уходил в бесконечную прокрутку.
class _MedalList extends StatefulWidget {
  final List<_Placed> rows;
  final bool strong;
  const _MedalList({required this.rows, this.strong = false});
  @override
  State<_MedalList> createState() => _MedalListState();
}

class _MedalListState extends State<_MedalList> {
  static const _first = 6;
  bool all = false;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final rows = widget.rows;
    // «Ещё 1» не прячет ничего: семь строк показываем целиком
    final list = all || rows.length <= _first + 1 ? rows : rows.sublist(0, _first);
    final more = rows.length - list.length;
    return Plate(
      child: Column(
        children: [
          for (var i = 0; i < list.length; i++) ...[
            if (i > 0) const Hairline(indent: 54),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 16, 10),
              child: Row(
                children: [
                  SizedBox(
                    width: 28,
                    child: list[i].place != null
                        ? Medal(list[i].place!, size: 28)
                        : Text(
                            list[i].mark.isEmpty ? '—' : list[i].mark,
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: p.ink2),
                          ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          list[i].event,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: widget.strong ? FontWeight.w700 : FontWeight.w600,
                            color: p.ink,
                            height: 1.3,
                          ),
                        ),
                        if (list[i].note.isNotEmpty)
                          Text(list[i].note, style: TextStyle(fontSize: 13, color: p.ink2, height: 1.3)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (more > 0) ...[
            const Hairline(indent: 54),
            Semantics(
              button: true,
              child: InkWell(
                onTap: () => setState(() => all = true),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(54, 12, 16, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Ещё $more',
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: p.accent),
                          ),
                        ),
                        Icon(CupertinoIcons.chevron_down, size: 16, color: p.accent),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Личные рекорды или лучшее в сезоне: сегмент и турнир слева, баллы крупно справа.
class _Scores extends StatelessWidget {
  final List<ProfileScore> list;
  final bool dance;
  const _Scores({required this.list, required this.dance});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Plate(
      child: Column(
        children: [
          for (var i = 0; i < list.length; i++) ...[
            if (i > 0) const Hairline(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Eyebrow(segLabel(list[i].seg, dance: dance)),
                        const SizedBox(height: 4),
                        Text(list[i].event, style: TextStyle(fontSize: 14, color: p.ink, height: 1.3)),
                        if (list[i].date.isNotEmpty)
                          Text(profileDate(list[i].date), style: TextStyle(fontSize: 13, color: p.ink2, height: 1.3)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    list[i].points,
                    style: clock(
                      list[i].seg == 'total' ? p.ink : p.ink2,
                      list[i].seg == 'total' ? 26 : 22,
                      weight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Примечательное: что сделано, где и когда; у рекорда — баллы справа. Строка ведёт к источнику
/// (стрелка «наружу», но открывается внутри приложения). Длинный список — первые шесть и «Ещё N».
class _Feats extends StatefulWidget {
  final List<ProfileFeat> list;
  const _Feats({required this.list});
  @override
  State<_Feats> createState() => _FeatsState();
}

class _FeatsState extends State<_Feats> {
  static const _first = 6;
  bool all = false;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final rows = widget.list;
    final list = all || rows.length <= _first + 1 ? rows : rows.sublist(0, _first);
    final more = rows.length - list.length;
    return Plate(
      child: Column(
        children: [
          for (var i = 0; i < list.length; i++) ...[
            if (i > 0) const Hairline(),
            _FeatRow(list[i]),
          ],
          if (more > 0) ...[
            const Hairline(),
            Semantics(
              button: true,
              child: InkWell(
                onTap: () => setState(() => all = true),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Ещё $more',
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: p.accent),
                          ),
                        ),
                        Icon(CupertinoIcons.chevron_down, size: 16, color: p.accent),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _FeatRow extends StatelessWidget {
  final ProfileFeat f;
  const _FeatRow(this.f);
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final row = Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 14, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(f.title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: p.ink, height: 1.3)),
                if (f.event.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(f.event, style: TextStyle(fontSize: 14, color: p.ink, height: 1.3)),
                ],
                if (f.date.isNotEmpty)
                  Text(profileDate(f.date), style: TextStyle(fontSize: 13, color: p.ink2, height: 1.3)),
              ],
            ),
          ),
          if (f.points.isNotEmpty) ...[
            const SizedBox(width: 12),
            Text(f.points, style: clock(p.ink, 22, weight: FontWeight.w500)),
          ],
          if (f.url.isNotEmpty) ...[
            const SizedBox(width: 10),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(CupertinoIcons.arrow_up_right, size: 15, color: p.ink3),
            ),
          ],
        ],
      ),
    );
    if (f.url.isEmpty) return row;
    return Semantics(
      button: true,
      hint: f.source.isEmpty ? 'Открыть источник' : 'Открыть источник: ${f.source}',
      child: InkWell(
        onTap: () => openLink(context, f.url, f.source.isEmpty ? f.title : f.source),
        child: row,
      ),
    );
  }
}

/// Старты сезона из картотеки ФФККР: турнир, категория, место.
class _Season extends StatelessWidget {
  final List<ProfileStart> list;
  const _Season({required this.list});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Plate(
      child: Column(
        children: [
          for (var i = 0; i < list.length; i++) ...[
            if (i > 0) const Hairline(),
            Builder(
              builder: (context) {
                final (place, cat) = splitPlace(list[i].place);
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 11, 16, 11),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              list[i].event,
                              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: p.ink, height: 1.3),
                            ),
                            if (place != null && cat.isNotEmpty)
                              Text('категория $cat', style: TextStyle(fontSize: 13, color: p.ink2, height: 1.3)),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      if (place != null)
                        Medal(place, size: 28)
                      else
                        Text(cat.isEmpty ? '—' : cat, style: TextStyle(fontSize: 13.5, color: p.ink2)),
                    ],
                  ),
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Plate(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
      child: Row(
        children: [
          SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: p.accent)),
          const SizedBox(width: 14),
          Expanded(
            child: Text('Загружаю справку', style: TextStyle(fontSize: 15, color: p.ink2)),
          ),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  final String text;
  final String? action;
  final VoidCallback? onAction;
  const _Note(this.text, {this.action, this.onAction});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Plate(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text, style: TextStyle(fontSize: 15, color: p.ink2, height: 1.35)),
          if (action != null) ...[
            const SizedBox(height: 12),
            SheetButton(label: action!, onTap: onAction, compact: true),
          ],
        ],
      ),
    );
  }
}
