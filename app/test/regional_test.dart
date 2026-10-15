import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:starty/data.dart';
import 'package:starty/sync.dart';

Map<String, dynamic> start({String? tier, String? region}) => {
  'id': 'r1',
  'tid': 't1',
  'tournament': 'Первенство Москвы',
  'kind': 'women',
  'level': 'junior',
  'seg': 'short',
  'title': 'Короткая программа',
  'venue': 'Москва',
  'src': 'ФФКМ',
  'start': '2026-08-24T15:00:00+03:00',
  'end': '2026-08-24T18:00:00+03:00',
  'intl': false,
  'tier': ?tier,
  'region': ?region,
};

void main() {
  test('старт федерации региона помечается региональным и несёт регион', () {
    final s = Start.fromJson(start(tier: 'regional', region: 'Москва'));
    expect(s.regional, isTrue);
    expect(s.region, 'Москва');
  });

  test('без метки — федеральный старт, регион пустой', () {
    final s = Start.fromJson(start());
    expect(s.regional, isFalse);
    expect(s.region, '');
  });

  test('регион переживает пересборку карточки с итогами', () {
    final s = Start.fromJson(start(tier: 'regional', region: 'Самарская область'));
    final again = s.withResults(
      podium: const [],
      provisional: false,
      places: const {},
      total: const [],
      finals: const {},
    );
    expect(again.regional, isTrue);
    expect(again.region, 'Самарская область');
  });

  test('флаг региональных стартов уходит на сервер и приходит обратно', () {
    final d = SyncDoc(
      updatedAt: DateTime.utc(2026, 10, 15),
      rules: '{}',
      forcedOn: const [],
      forcedOff: const [],
      follow: const [],
      followRussians: true,
      followBelarusians: true,
      filters: const {'kinds': [], 'tids': [], 'athletes': [], 'levels': [], 'scope': []},
      showDone: true,
      theme: 'system',
      icon: 'classic',
      regional: true,
    );
    final back = SyncDoc.fromJson(jsonDecode(jsonEncode(d.toJson())) as Map<String, dynamic>);
    expect(back.regional, isTrue);
    // у документа старой версии поля нет — выключено
    expect(SyncDoc.fromJson({'v': 1}).regional, isFalse);
  });
}
