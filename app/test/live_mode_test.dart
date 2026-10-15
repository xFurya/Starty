// Режим живых мест: общий и для старта. Хранение в Prefs, круг через документ настроек (SyncDoc).
// Документ без новых полей (старые версии) не сбрасывает настройку устройства.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:starty/data.dart';
import 'package:starty/sync.dart';

SyncDoc doc({String liveMode = liveDelayed, Map<String, String> overrides = const {'ffkm:2026-08-24_pm:dance-junior-rt': liveInstant}}) => SyncDoc(
  updatedAt: DateTime.utc(2026, 10, 15, 19, 5),
  rules: '{"on":true}',
  forcedOn: const [],
  forcedOff: const [],
  follow: null,
  followRussians: true,
  followBelarusians: true,
  filters: const {'kinds': [], 'tids': [], 'athletes': [], 'levels': [], 'scope': []},
  showDone: true,
  theme: 'system',
  icon: 'classic',
  liveMode: liveMode,
  liveOverrides: overrides,
);

SyncDoc wire(SyncDoc d) => SyncDoc.fromJson(jsonDecode(jsonEncode(d.toJson())) as Map<String, dynamic>);

void main() {
  group('действующий режим старта', () {
    test('переопределение старта важнее общего режима', () {
      expect(effectiveLiveMode(liveDelayed, {'a': liveInstant}, 'a'), liveInstant);
      expect(effectiveLiveMode(liveInstant, {'a': liveDelayed}, 'a'), liveDelayed);
    });
    test('нет переопределения — общий режим', () {
      expect(effectiveLiveMode(liveDelayed, {'b': liveInstant}, 'a'), liveDelayed);
      expect(effectiveLiveMode(liveInstant, const {}, 'a'), liveInstant);
    });
    test('по умолчанию — моментально, как было', () {
      expect(validLiveMode(null), isNull);
      expect(validLiveMode('turbo'), isNull);
      expect(validLiveMode('delayed'), liveDelayed);
    });
  });

  group('Prefs: хранение на устройстве', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await Prefs.init();
    });

    test('по умолчанию — моментально, переопределений нет', () {
      expect(Prefs.liveMode, liveInstant);
      expect(Prefs.liveOverrides, isEmpty);
    });
    test('общий режим сохраняется и читается', () async {
      await Prefs.setLiveMode(liveDelayed);
      expect(Prefs.liveMode, liveDelayed);
    });
    test('неизвестный режим при записи — моментально', () async {
      await Prefs.setLiveMode('что-то');
      expect(Prefs.liveMode, liveInstant);
    });
    test('переопределения сохраняются по id, пустые и чужие значения отбрасываются', () async {
      await Prefs.setLiveOverrides({'a': liveDelayed, 'b': 'мусор', 'c': liveInstant});
      expect(Prefs.liveOverrides, {'a': liveDelayed, 'c': liveInstant});
    });
    test('испорченная запись — пусто, экран не падает', () async {
      SharedPreferences.setMockInitialValues({'live.over': '[не объект'});
      await Prefs.init();
      expect(Prefs.liveOverrides, isEmpty);
    });
  });

  group('документ настроек: поля liveMode и liveOverrides', () {
    test('круг туда-обратно сохраняет оба поля', () {
      final back = wire(doc());
      expect(back.liveMode, liveDelayed);
      expect(back.liveOverrides, {'ffkm:2026-08-24_pm:dance-junior-rt': liveInstant});
      expect(back.absent, isNot(contains('liveMode')));
      expect(back.absent, isNot(contains('liveOverrides')));
    });
    test('документ целиком: второй круг даёт тот же JSON', () {
      final once = jsonEncode(doc().toJson());
      expect(jsonEncode(wire(doc()).toJson()), once);
    });
    test('пустые переопределения — явный «ничего не переопределено», не пропуск', () {
      final back = wire(doc(overrides: const {}));
      expect(back.liveOverrides, isEmpty);
      expect(back.absent, isNot(contains('liveOverrides')));
    });
    test('при смене времени документ сохраняет поля', () {
      final t = doc().at(DateTime.utc(2026, 10, 15, 20));
      expect(t.liveMode, liveDelayed);
      expect(t.liveOverrides, isNotEmpty);
    });
    test('старый документ без полей — оба поля пропущены: устройство не сбрасывает свою настройку', () {
      final j = doc().toJson()..remove('liveMode')..remove('liveOverrides');
      final old = SyncDoc.fromJson(j);
      expect(old.absent, containsAll(['liveMode', 'liveOverrides']));
      expect(old.liveMode, liveInstant, reason: 'для чтения — по умолчанию, но не применяется');
    });
    test('испорченный режим — пропуск, переопределения с мусором — отбрасываются поэлементно', () {
      final j = doc().toJson()
        ..['liveMode'] = 'turbo'
        ..['liveOverrides'] = {'a': 'delayed', 'b': 42, 'c': 'bogus'};
      final d = SyncDoc.fromJson(j);
      expect(d.absent, contains('liveMode'));
      expect(d.liveOverrides, {'a': liveDelayed});
    });
    test('переопределения не объект — пропуск поля', () {
      final j = doc().toJson()..['liveOverrides'] = 'нет';
      expect(SyncDoc.fromJson(j).absent, contains('liveOverrides'));
    });
  });

  group('круг через Prefs: сохранить здесь → документ → применить на другом устройстве', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await Prefs.init();
    });

    test('общий режим и переопределения переезжают целиком', () async {
      // устройство А: сохранило режим и переопределение старта
      await Prefs.setLiveMode(liveDelayed);
      await Prefs.setLiveOverrides({'ffkm:2026-08-24_pm:dance-junior-rt': liveInstant});
      final fromDevice = SyncDoc(
        updatedAt: DateTime.utc(2026, 10, 15),
        rules: '{}',
        forcedOn: const [],
        forcedOff: const [],
        follow: null,
        followRussians: true,
        followBelarusians: true,
        filters: const {'kinds': [], 'tids': [], 'athletes': [], 'levels': [], 'scope': []},
        showDone: true,
        theme: 'system',
        icon: 'classic',
        liveMode: Prefs.liveMode,
        liveOverrides: Prefs.liveOverrides,
      );
      // устройство Б: другие значения; применяем документ так же, как AppState._applySync
      await Prefs.setLiveMode(liveInstant);
      await Prefs.setLiveOverrides({'other': liveDelayed});
      final d = wire(fromDevice);
      if (!d.absent.contains('liveMode')) await Prefs.setLiveMode(d.liveMode);
      if (!d.absent.contains('liveOverrides')) await Prefs.setLiveOverrides(d.liveOverrides);
      expect(Prefs.liveMode, liveDelayed);
      expect(Prefs.liveOverrides, {'ffkm:2026-08-24_pm:dance-junior-rt': liveInstant});
    });

    test('документ без полей не меняет режим устройства', () async {
      await Prefs.setLiveMode(liveDelayed);
      final old = SyncDoc.fromJson(doc().toJson()..remove('liveMode')..remove('liveOverrides'));
      if (!old.absent.contains('liveMode')) await Prefs.setLiveMode(old.liveMode);
      expect(Prefs.liveMode, liveDelayed);
    });
  });
}
