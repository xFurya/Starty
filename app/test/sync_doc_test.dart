// Документ настроек: круг туда-обратно для каждого поля, версии 1 и 2, отслеживаемые по умолчанию,
// выбор значка и отслеживаемых при сохранении.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:starty/sync.dart';

/// Документ, в котором каждое поле отличается от значения по умолчанию.
SyncDoc full({List<String>? follow = const ['Камила Валиева', 'Аделия Петросян']}) => SyncDoc(
  updatedAt: DateTime.utc(2026, 10, 15, 10, 5),
  rules: '{"on":false,"lead":30}',
  forcedOn: const ['isu:a-1'],
  forcedOff: const ['isu:a-2'],
  follow: follow,
  followRussians: false,
  followBelarusians: false,
  filters: const {
    'kinds': ['women'],
    'tids': ['isu:t-1'],
    'athletes': ['Камила Валиева'],
    'levels': ['senior'],
    'scope': ['intl'],
  },
  showDone: false,
  theme: 'dark',
  icon: 'skate_teal',
  regional: true,
);

/// Туда и обратно через текст, как в хранилище.
SyncDoc wire(SyncDoc d) => SyncDoc.fromJson(jsonDecode(jsonEncode(d.toJson())) as Map<String, dynamic>);

/// Документ версии 1 в том виде, как его писало прошлое приложение.
Map<String, dynamic> v1({List<Object?> follow = const []}) => {
  'v': 1,
  'updatedAt': '2026-10-15T10:05:00.000Z',
  'rules': '{"on":true}',
  'forcedOn': <String>[],
  'forcedOff': <String>[],
  'follow': follow,
  'followRussians': true,
  'followBelarusians': true,
  'filters': {
    'kinds': <String>[],
    'tids': <String>[],
    'athletes': <String>[],
    'levels': <String>[],
    'scope': <String>[],
  },
  'showDone': true,
  'theme': 'light',
  'icon': 'classic',
  'regional': false,
};

void main() {
  group('версия 2: круг туда-обратно для каждого поля', () {
    test('версия записывается как 2', () {
      expect(full().toJson()['v'], 2);
    });
    test('время изменения', () {
      expect(wire(full()).updatedAt, DateTime.utc(2026, 10, 15, 10, 5));
    });
    test('правила уведомлений (строка)', () {
      expect(wire(full()).rules, '{"on":false,"lead":30}');
    });
    test('исключения: включённые и выключенные вручную', () {
      final d = wire(full());
      expect(d.forcedOn, ['isu:a-1']);
      expect(d.forcedOff, ['isu:a-2']);
    });
    test('отслеживаемые', () {
      expect(wire(full()).follow, ['Камила Валиева', 'Аделия Петросян']);
    });
    test('все россияне и все белорусы — по отдельности', () {
      final d = wire(full());
      expect(d.followRussians, isFalse);
      expect(d.followBelarusians, isFalse);
    });
    test('фильтр ленты — все пять ключей', () {
      final f = wire(full()).filters;
      expect(f.keys, unorderedEquals(['kinds', 'tids', 'athletes', 'levels', 'scope']));
      expect(f['kinds'], ['women']);
      expect(f['tids'], ['isu:t-1']);
      expect(f['athletes'], ['Камила Валиева']);
      expect(f['levels'], ['senior']);
      expect(f['scope'], ['intl']);
    });
    test('показ завершённых', () {
      expect(wire(full()).showDone, isFalse);
    });
    test('тема', () {
      expect(wire(full()).theme, 'dark');
    });
    test('значок', () {
      expect(wire(full()).icon, 'skate_teal');
    });
    test('региональные федерации', () {
      expect(wire(full()).regional, isTrue);
    });
    test('документ целиком: второй круг даёт тот же JSON', () {
      expect(wire(full()).toJson(), full().toJson());
    });
  });

  group('отслеживаемые по умолчанию (null)', () {
    test('null записывается как null и читается как null', () {
      final d = full(follow: null);
      expect(d.toJson()['follow'], isNull);
      expect(wire(d).follow, isNull);
    });
    test('пустой список в версии 2 — явный выбор «никого», не null', () {
      final back = wire(full(follow: const []));
      expect(back.follow, isEmpty);
      expect(back.follow, isNotNull);
    });
    test('поля нет в версии 2 — null', () {
      final j = full().toJson()..remove('follow');
      expect(SyncDoc.fromJson(j).follow, isNull);
    });
    test('поле не список — null', () {
      final j = full().toJson()..['follow'] = 'Камила Валиева';
      expect(SyncDoc.fromJson(j).follow, isNull);
    });
    test('в списке только строки: чужие элементы отбрасываются', () {
      final j = full().toJson()..['follow'] = ['Камила Валиева', 7, null];
      expect(SyncDoc.fromJson(j).follow, ['Камила Валиева']);
    });
  });

  group('версия 1', () {
    test('пустой список — «не выбирал» (null)', () {
      expect(SyncDoc.fromJson(v1()).follow, isNull);
    });
    test('непустой список — явный выбор, сохраняется', () {
      expect(SyncDoc.fromJson(v1(follow: ['Камила Валиева'])).follow, ['Камила Валиева']);
    });
    test('остальные поля читаются как раньше', () {
      final d = SyncDoc.fromJson(v1());
      expect(d.updatedAt, DateTime.utc(2026, 10, 15, 10, 5));
      expect(d.rules, '{"on":true}');
      expect(d.theme, 'light');
      expect(d.icon, 'classic');
      expect(d.showDone, isTrue);
      expect(d.regional, isFalse);
      expect(d.followRussians, isTrue);
      expect(d.followBelarusians, isTrue);
    });
    test('документ без версии читается как версия 1', () {
      final j = v1()..remove('v');
      expect(SyncDoc.fromJson(j).follow, isNull);
    });
    test('будущая версия читается как текущая, неизвестные поля игнорируются', () {
      final d = SyncDoc.fromJson({...v1(follow: ['Камила Валиева']), 'v': 3, 'будущее': 42});
      expect(d.follow, ['Камила Валиева']);
    });
  });

  group('followToStore: выбор, совпавший со списком сборщика, — по умолчанию', () {
    test('совпало — null', () {
      expect(followToStore({'b', 'a'}, ['a', 'b']), isNull);
    });
    test('порядок и повторы не важны', () {
      expect(followToStore(['a', 'a', 'b'], ['b', 'a']), isNull);
    });
    test('отличается — явный список, отсортированный', () {
      expect(followToStore({'b', 'a'}, ['a']), ['a', 'b']);
    });
    test('список сборщика ещё не загружен — выбор как есть', () {
      expect(followToStore({'a'}, null), ['a']);
    });
    test('пустой выбор при непустом списке сборщика — явный пустой список', () {
      final got = followToStore(const <String>{}, ['a']);
      expect(got, isEmpty);
      expect(got, isNotNull);
    });
    test('пустой выбор при пустом списке сборщика — по умолчанию', () {
      expect(followToStore(const <String>{}, const <String>[]), isNull);
    });
  });

  group('iconToSync: значок документа не теряется на устройстве, где его нет', () {
    test('значок здесь есть — берём показанный', () {
      expect(
        iconToSync(device: 'skate_teal', docIcon: 'date_orange', lastDevice: 'classic'),
        'skate_teal',
      );
    });
    test('документа нет — берём показанный', () {
      expect(iconToSync(device: 'classic', docIcon: null, lastDevice: null), 'classic');
    });
    test('датированного здесь нет, значок не меняли — сохраняем значок документа', () {
      expect(
        iconToSync(device: 'classic', docIcon: 'date_orange', lastDevice: 'classic'),
        'date_orange',
      );
    });
    test('датированного здесь нет, значок поменяли здесь — берём здешний', () {
      expect(
        iconToSync(device: 'skate_teal', docIcon: 'date_orange', lastDevice: 'classic'),
        'skate_teal',
      );
    });
    test('датированного здесь нет, прошлой сверки не помним — сохраняем значок документа', () {
      expect(
        iconToSync(device: 'classic', docIcon: 'date_orange', lastDevice: null),
        'date_orange',
      );
    });
    test('значок здесь есть, но система его не поставила, и не менялся — сохраняем значок документа', () {
      expect(
        iconToSync(device: 'classic', docIcon: 'skate_teal', lastDevice: 'classic'),
        'skate_teal',
      );
    });
  });

  group('absent: поле, которого в документе нет или которое испорчено, не применяется', () {
    test('нет поля — в absent, значение по умолчанию только для чтения', () {
      final d = SyncDoc.fromJson(full().toJson()..remove('theme')..remove('regional'));
      expect(d.absent, containsAll(['theme', 'regional']));
      expect(d.theme, 'system');
    });
    test('испорченное поле — в absent', () {
      final j = full().toJson()
        ..['theme'] = 'purple'
        ..['showDone'] = 'да'
        ..['forcedOn'] = 'isu:a-1';
      expect(SyncDoc.fromJson(j).absent, containsAll(['theme', 'showDone', 'forcedOn']));
    });
    test('документ, собранный здесь, без пропусков', () {
      expect(wire(full()).absent, isEmpty);
    });
    test('отслеживаемые null — явный выбор «по умолчанию», не пропуск', () {
      expect(wire(full(follow: null)).absent, isNot(contains('follow')));
    });
    test('нет отслеживаемых — пропуск', () {
      final j = full().toJson()..remove('follow');
      expect(SyncDoc.fromJson(j).absent, contains('follow'));
    });
    test('версия 1 без региональных федераций — поле пропущено, не выключено', () {
      expect(SyncDoc.fromJson({'v': 1}).absent, contains('regional'));
    });
    test('фильтр без одного ключа — пропущен только он', () {
      final j = full().toJson()..['filters'] = {'kinds': ['women']};
      final absent = SyncDoc.fromJson(j).absent;
      expect(absent, containsAll(['filters.tids', 'filters.athletes', 'filters.levels', 'filters.scope']));
      expect(absent, isNot(contains('filters.kinds')));
    });
    test('неизвестная тема — пропуск', () {
      expect(SyncDoc.fromJson(full().toJson()..['theme'] = 'system').absent, isNot(contains('theme')));
      expect(SyncDoc.fromJson(full().toJson()..['theme'] = 'purple').absent, contains('theme'));
    });
  });
}
