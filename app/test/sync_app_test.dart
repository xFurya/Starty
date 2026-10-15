// Настройки приложения и документ: каждая настройка отмечает правку, применение документа не
// отмечает её (нет эха), захват → применение → захват даёт тот же документ, отслеживаемые по умолчанию
// не замораживаются, датированный значок на iPhone не ставится и не теряется.
// Настройки с обновлением состояния и сверкой (_sync) не ждём: правка отмечается раньше, а сверка
// без расписания и без инициализации уведомлений ничего не делает и завершается сама.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:starty/data.dart';
import 'package:starty/reminders.dart';
import 'package:starty/state.dart';
import 'package:starty/sync.dart';

Future<void> freshPrefs() async {
  SharedPreferences.setMockInitialValues({});
  await Prefs.init();
}

/// Туда и обратно через текст, как в хранилище.
SyncDoc wire(SyncDoc d) => SyncDoc.fromJson(jsonDecode(jsonEncode(d.toJson())) as Map<String, dynamic>);

/// Расписание из образца; watchlist — список сборщика (отслеживаемые по умолчанию).
Schedule sample({List<String>? watchlist}) {
  final j = jsonDecode(File('test/podium_sample.json').readAsStringSync()) as Map<String, dynamic>;
  if (watchlist != null) j['watchlist'] = watchlist;
  return Schedule.parse(jsonEncode(j));
}

/// Образец с одним региональным стартом федерации (федерации выключены по умолчанию).
Schedule withRegional() {
  final j = jsonDecode(File('test/podium_sample.json').readAsStringSync()) as Map<String, dynamic>;
  (j['events'] as List).add({
    'id': 'reg-1',
    'tid': 'reg-t1',
    'tournament': 'Первенство Москвы',
    'kind': 'women',
    'level': 'junior',
    'seg': 'КП',
    'title': 'Короткая программа',
    'venue': 'Москва',
    'src': 'ФФКМ',
    'start': '2026-10-20T15:00:00+03:00',
    'end': '2026-10-20T18:00:00+03:00',
    'intl': false,
    'tier': 'regional',
    'region': 'Москва',
  });
  return Schedule.parse(jsonEncode(j));
}

/// Дать очереди событий доработать (правка отмечается асинхронно).
Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 50));

void main() {
  // значки читаются из ресурсов приложения (rootBundle): нужен биндинг, как у приложения
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await freshPrefs();
    // во флаттер-тестах платформа по умолчанию — Android, а значки там идут через нативный канал;
    // здесь значок хранится в preferences, как на компьютере (iPhone проверяем отдельно)
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  group('каждая настройка отмечает правку (touchSync)', () {
    final cases = <String, Future<void> Function(AppState s)>{
      'правила уведомлений': (s) => s.setRules(const NotifyRules(lead: 30)),
      'ручное включение или выключение старта': (s) => s.toggleStart(sample().starts.first),
      'сброс исключений': (s) => s.clearExceptions(),
      'фильтр ленты': (s) => s.setFilters(const Filters({'women'}, {}, {})),
      'показ завершённых': (s) => s.setShowDone(false),
      'региональные федерации': (s) => s.setRegional(true),
      'тема': (s) => s.setTheme(ThemeMode.dark),
      'отслеживаемые': (s) => s.setFollow({'Камила Валиева'}, russians: false, belarusians: true),
    };
    for (final e in cases.entries) {
      test(e.key, () async {
        final local = SyncLocal(Prefs.raw);
        final s = AppState();
        expect(local.state.pending, isFalse);
        // setter с _sync ждёт уведомления до 10 с: правка уже отмечена, не ждём весь вызов
        unawaited(e.value(s));
        await settle();
        expect(local.state.pending, isTrue);
      });
    }
  });

  test('применение документа не отмечает правку: нет эха', () async {
    final local = SyncLocal(Prefs.raw);
    final s = AppState();
    await s.sync.apply(SyncDoc.fromJson({'v': 2, 'theme': 'dark', 'follow': ['Камила Валиева']}));
    await settle();
    expect(local.state.pending, isFalse);
  });

  test('захват → применение → захват даёт тот же документ, каждое поле на месте', () async {
    // первое устройство: всё не по умолчанию (настройки читаются при создании состояния — сначала пишем)
    await Prefs.setRulesJson(
      const NotifyRules(
        on: false,
        lead: 30,
        kinds: {'men'},
        levels: {'junior'},
        segs: {'free'},
        russian: false,
        night: false,
        skaters: true,
        onlyFollowed: true,
        gone: 30,
        skaterLead: 5,
        pin: false,
        clear: false,
      ).toJson(),
    );
    await Prefs.setForced({'isu:a-1'}, {'isu:a-2'});
    await Prefs.setFollow(['Камила Валиева'], russians: false, belarusians: true);
    await Prefs.setFilters(const Filters({'women'}, {'isu:t-1'}, {'Камила Валиева'}, levels: {'senior'}, scope: {'intl'}));
    await Prefs.setShowDone(false);
    await Prefs.setRegional(true);
    await Prefs.setTheme('dark');
    await Prefs.raw.setString('icon', 'skate_teal');

    final first = AppState();
    final d1 = await first.sync.capture();
    final doc = wire(d1);

    // второе устройство: чистые настройки, документ с первого
    await freshPrefs();
    final second = AppState();
    expect(second.rules.on, isTrue); // до применения — по умолчанию
    await second.sync.apply(doc);

    expect(second.rules.on, isFalse);
    expect(second.rules.lead, 30);
    expect(second.rules.kinds, {'men'});
    expect(second.rules.skaterLead, 5);
    expect(second.forcedOn, {'isu:a-1'});
    expect(second.forcedOff, {'isu:a-2'});
    expect(second.follow.names, {'Камила Валиева'});
    expect(second.follow.russians, isFalse);
    expect(second.follow.belarusians, isTrue);
    expect(second.filters.kinds, {'women'});
    expect(second.filters.tids, {'isu:t-1'});
    expect(second.filters.athletes, {'Камила Валиева'});
    expect(second.filters.levels, {'senior'});
    expect(second.filters.scope, {'intl'});
    expect(second.showDone, isFalse);
    expect(second.regional, isTrue);
    expect(second.theme, ThemeMode.dark);

    final d2 = await second.sync.capture();
    expect(d2.toJson(), d1.toJson());
  });

  test('отслеживаемые по умолчанию: документ с null приносит список по умолчанию, а не пустой', () async {
    final s = AppState()..adoptSchedule(sample(watchlist: ['Камила Валиева', 'Аделия Петросян']));
    await s.sync.apply(SyncDoc.fromJson({'v': 2, 'follow': null}));
    expect(Prefs.follow, isNull);
    expect(s.follow.names, {'Камила Валиева', 'Аделия Петросян'});
    expect((await s.sync.capture()).follow, isNull);
  });

  test('версия 1 с пустым списком: отслеживаемые снова по умолчанию', () async {
    final s = AppState()..adoptSchedule(sample(watchlist: ['Камила Валиева']));
    await s.sync.apply(SyncDoc.fromJson({'v': 1, 'follow': <String>[]}));
    expect(Prefs.follow, isNull);
    expect(s.follow.names, {'Камила Валиева'});
  });

  test('выбрали только россиян, список остался по умолчанию: сборщик его и дальше ведёт', () async {
    const watch = {'Камила Валиева', 'Аделия Петросян'};
    final s = AppState()..adoptSchedule(sample(watchlist: watch.toList()));
    unawaited(s.setFollow(watch, russians: false, belarusians: true));
    await settle();
    expect(Prefs.follow, isNull);
    expect((await s.sync.capture()).follow, isNull);
    expect(Prefs.followRussians, isFalse);

    // сборщик обновил список: у этого устройства он новый
    s.adoptSchedule(sample(watchlist: ['Анна Щербакова']));
    expect(s.follow.names, {'Анна Щербакова'});
    expect(s.follow.russians, isFalse);
  });

  test('датированный значок с другого устройства на iPhone не ставится и не теряется', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final p = Prefs.raw;
    await p.setString('icon', 'classic'); // что показано на iPhone

    final s = AppState();
    await s.sync.apply(SyncDoc.fromJson({'v': 2, 'icon': 'date_orange'}));
    expect(p.getString('icon'), 'classic'); // здесь такого не ставим
    expect((await s.sync.capture()).icon, 'date_orange'); // документ сохранил свой значок

    await p.setString('icon', 'skate_teal'); // человек выбрал значок здесь
    expect((await s.sync.capture()).icon, 'skate_teal');
  });

  test('исключение регионального старта переживает выключенные федерации', () async {
    await Prefs.setRegional(false);
    await Prefs.setForced({'reg-1', 'gone-9'}, {});
    final s = AppState()..adoptSchedule(withRegional());
    s.prune();
    // старт в расписании есть, федерации выключены: исключение на нём остаётся, мёртвое — уходит
    expect(s.forcedOn, {'reg-1'});
    expect(Prefs.forcedOn, {'reg-1'});
  });

  test('отслеживаемые без расписания: выбор флагов не превращает список в явный «никого»', () async {
    final s = AppState(); // расписания ещё нет: список сборщика неизвестен
    unawaited(s.setFollow(const {}, russians: false, belarusians: true));
    await settle();
    expect(Prefs.follow, isNull);
    expect(Prefs.followRussians, isFalse);
    expect((await s.sync.capture()).follow, isNull);
  });

  test('значок, который система не поставила, не затирает значок документа', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    const channel = MethodChannel('starty/icon');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'get') return 'classic';
      if (call.method == 'set') return false; // система отказала
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final s = AppState();
    await s.sync.apply(SyncDoc.fromJson({'v': 2, 'icon': 'skate_teal'}));
    expect((await s.sync.capture()).icon, 'skate_teal');
  });

  test('документ без полей не стирает настройки устройства', () async {
    await Prefs.setTheme('dark');
    await Prefs.setShowDone(false);
    await Prefs.setRegional(true);
    await Prefs.setRulesJson(const NotifyRules(on: false, lead: 30).toJson());
    await Prefs.setForced({'isu:a-1'}, {});
    await Prefs.setFilters(const Filters({'women'}, {}, {}));
    await Prefs.setFollow(['Камила Валиева'], russians: false, belarusians: true);

    final s = AppState();
    await s.sync.apply(SyncDoc.fromJson({'v': 2}));
    expect(Prefs.theme, 'dark');
    expect(Prefs.showDone, isFalse);
    expect(Prefs.regional, isTrue);
    expect(NotifyRules.fromJson(Prefs.rulesJson).on, isFalse);
    expect(NotifyRules.fromJson(Prefs.rulesJson).lead, 30);
    expect(Prefs.forcedOn, {'isu:a-1'});
    expect(Prefs.kinds, {'women'});
    expect(Prefs.follow, ['Камила Валиева']);
    expect(Prefs.followRussians, isFalse);
    expect(Prefs.followBelarusians, isTrue);
  });

  test('испорченная строка правил не включает уведомления, которые человек выключил', () async {
    await Prefs.setRulesJson(const NotifyRules(on: false).toJson());
    final s = AppState();
    await s.sync.apply(SyncDoc.fromJson({'v': 2, 'rules': '{"on": tr'}));
    expect(NotifyRules.fromJson(Prefs.rulesJson).on, isFalse);
  });
}
