// Загрузка файла протокола: сеть, 404, сбой, кэш на устройстве (восемь турниров), окончательное не затирается.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:starty/protocol_model.dart';
import 'package:starty/protocol_repo.dart';

final _now = DateTime.utc(2026, 10, 15, 19, 0); // 22:00 по Москве

Map<String, dynamic> sample() => jsonDecode(File('test/protocol/sample.json').readAsStringSync()) as Map<String, dynamic>;

/// Тот же файл, но сегмент ритм-танца промежуточный (судейских оценок ещё нет).
Map<String, dynamic> provisional() {
  final j = sample();
  final s = ((j['categories'] as List).first as Map)['segments'].first as Map<String, dynamic>;
  s['state'] = 'in_progress';
  s['basis'] = null;
  return j;
}

ProtocolRepo repo(http.Client c) => ProtocolRepo(client: c, now: () => _now);

/// Ответ в UTF-8 байтах, как с сайта: кириллица не должна проходить через latin1.
http.Response ok(Object body) => http.Response.bytes(utf8.encode(jsonEncode(body)), 200, headers: {'content-type': 'application/json; charset=utf-8'});

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('исходы загрузки', () {
    test('200 и разбор: окончательный файл', () async {
      final r = await repo(MockClient((_) async => ok(sample()))).load('ffkm_2026-08-24_pm.json');
      expect(r, isA<ProtocolOk>());
      expect((r as ProtocolOk).doc.categories.first.segments.first.state, SegmentState.finalized);
    });

    test('404 — файла нет (турнир ещё не собран)', () async {
      final r = await repo(MockClient((_) async => http.Response('', 404))).load('x.json');
      expect(r, isA<ProtocolMissing>());
    });

    test('таймаут без кэша — сеть, кэша нет', () async {
      final r = await repo(MockClient((_) async => throw TimeoutException('15 с'))).load('x.json');
      expect(r, isA<ProtocolNetError>());
      expect((r as ProtocolNetError).cached, isNull);
    });

    test('5xx — сеть, не «файла нет»', () async {
      final r = await repo(MockClient((_) async => http.Response('oops', 503))).load('x.json');
      expect(r, isA<ProtocolNetError>());
    });

    test('бросок клиента — сеть', () async {
      final r = await repo(MockClient((_) async => throw const SocketLike())).load('x.json');
      expect(r, isA<ProtocolNetError>());
    });

    test('битый JSON — формат, в кэш не пишем', () async {
      final r = await repo(MockClient((_) async => http.Response.bytes(utf8.encode('{не json'), 200))).load('x.json');
      expect(r, isA<ProtocolFormatError>());
      expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
    });

    test('версия 2 — формат', () async {
      final j = sample()..['v'] = 2;
      expect(await repo(MockClient((_) async => ok(j))).load('x.json'), isA<ProtocolFormatError>());
    });

    test('имя файла не json — формат, сеть не трогаем', () async {
      var calls = 0;
      final r = await repo(MockClient((_) async {
        calls++;
        return ok(sample());
      })).load('../x.json');
      expect(r, isA<ProtocolFormatError>());
      expect(calls, 0);
    });
  });

  group('кэш на устройстве', () {
    test('удачная загрузка сохраняется; при сбое сети показывается сохранённая версия с временем', () async {
      final ok1 = await repo(MockClient((_) async => ok(sample()))).load('ffkm_2026-08-24_pm.json');
      expect(ok1, isA<ProtocolOk>());
      final later = ProtocolRepo(client: MockClient((_) async => http.Response('', 500)), now: () => _now.add(const Duration(hours: 1)));
      final r = await later.load('ffkm_2026-08-24_pm.json') as ProtocolNetError;
      expect(r.cached, isNotNull);
      expect(r.cached!.tournament, 'Первенство Москвы');
      expect(r.cachedAt, _now, reason: 'время сохранения, не время сбоя');
    });

    test('сбой сети не стирает кэш', () async {
      await repo(MockClient((_) async => ok(sample()))).load('a.json');
      await repo(MockClient((_) async => http.Response('', 500))).load('a.json');
      final again = await repo(MockClient((_) async => throw const SocketLike())).load('a.json');
      expect((again as ProtocolNetError).cached, isNotNull);
    });

    test('404 не стирает кэш и не пишется в него', () async {
      await repo(MockClient((_) async => ok(sample()))).load('a.json');
      await repo(MockClient((_) async => http.Response('', 404))).load('a.json');
      final net = await repo(MockClient((_) async => throw const SocketLike())).load('a.json');
      expect((net as ProtocolNetError).cached, isNotNull);
    });

    test('испорченная запись кэша не валит экран: загрузка работает без кэша', () async {
      SharedPreferences.setMockInitialValues({'protocol.file.a.json': 'не json'});
      final r = await repo(MockClient((_) async => ok(sample()))).load('a.json');
      expect(r, isA<ProtocolOk>());
    });

    test('восемь турниров: девятый вытесняет самый давний', () async {
      final r = repo(MockClient((_) async => ok(sample())));
      for (var i = 0; i < 9; i++) {
        await r.load('t$i.json');
      }
      final p = await SharedPreferences.getInstance();
      expect(p.getKeys().where((k) => k.startsWith('protocol.file.')), hasLength(ProtocolRepo.cacheLimit));
      expect(p.getKeys(), isNot(contains('protocol.file.t0.json')));
      expect(p.getKeys(), contains('protocol.file.t8.json'));
    });

    test('окончательный сегмент из кэша не заменяется промежуточным из свежей загрузки', () async {
      await repo(MockClient((_) async => ok(sample()))).load('a.json');
      final fresh = await repo(MockClient((_) async => ok(provisional()))).load('a.json') as ProtocolOk;
      final seg = fresh.doc.categories.first.segments.first;
      expect(seg.state, SegmentState.finalized, reason: 'сохранили окончательный');
      expect(seg.rows.first.points, '66.36');
      // кэш не перезаписан: сбой потом покажет тот же окончательный файл
      final net = await repo(MockClient((_) async => throw const SocketLike())).load('a.json') as ProtocolNetError;
      expect(net.cached!.categories.first.segments.first.state, SegmentState.finalized);
    });

    test('промежуточный файл без окончательного в кэше — записывается', () async {
      await repo(MockClient((_) async => ok(provisional()))).load('a.json');
      final net = await repo(MockClient((_) async => throw const SocketLike())).load('a.json') as ProtocolNetError;
      expect(net.cached!.categories.first.segments.first.state, SegmentState.inProgress);
    });
  });

  group('keepFinal: что сохраняем из старого файла', () {
    test('окончательный сегмент и итог сохраняются, если в новом их нет', () {
      final old = ProtocolDoc.fromJson(sample());
      final (merged, kept) = ProtocolRepo.keepFinal(ProtocolDoc.fromJson(provisional()), old);
      expect(kept, isTrue);
      expect(merged.categories.first.segments.first.state, SegmentState.finalized);
    });
    test('другой турнир — не трогаем', () {
      final other = sample()..['tid'] = 'isu:other';
      final (merged, kept) = ProtocolRepo.keepFinal(ProtocolDoc.fromJson(provisional()), ProtocolDoc.fromJson(other));
      expect(kept, isFalse);
      expect(merged.categories.first.segments.first.state, SegmentState.inProgress);
    });
    test('новый окончательный — берём новый, старый не нужен', () {
      final (merged, kept) = ProtocolRepo.keepFinal(ProtocolDoc.fromJson(sample()), ProtocolDoc.fromJson(provisional()));
      expect(kept, isFalse);
      expect(merged.categories.first.segments.first.state, SegmentState.finalized);
    });
  });
}

/// Бросок сети без подробностей: тесты не зависят от текста ошибки.
class SocketLike implements Exception {
  const SocketLike();
}
