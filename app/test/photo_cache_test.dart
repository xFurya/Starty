// Фото на диске: найденное не пропадает без сети и после перезапуска; кэш ограничен по размеру.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:starty/photo_cache.dart';

void main() {
  late Directory dir;
  var online = true;
  var calls = 0;
  final jpg = Uint8List.fromList(List.generate(64, (i) => i));

  setUp(() {
    dir = Directory.systemTemp.createTempSync('photos');
    PhotoCache.dirOverride = dir;
    PhotoCache.resetMemory();
    online = true;
    calls = 0;
    PhotoCache.client = MockClient((r) async {
      calls++;
      if (!online) throw const SocketException('нет сети');
      return http.Response.bytes(jpg, 200);
    });
  });
  tearDown(() {
    PhotoCache.dirOverride = null;
    PhotoCache.client = http.Client();
    dir.deleteSync(recursive: true);
  });

  test('после перезапуска и без сети фото берётся с диска', () async {
    expect(await PhotoCache.bytes('https://x.example/a.jpg'), jpg);
    PhotoCache.resetMemory();
    PhotoCache.dirOverride = dir;
    online = false;
    expect(await PhotoCache.bytes('https://x.example/a.jpg'), jpg);
    expect(calls, 1);
  });

  test('нет ни на диске, ни в сети — null (останется буква)', () async {
    online = false;
    expect(await PhotoCache.bytes('https://x.example/none.jpg'), isNull);
  });

  test('ответ не 200 не кладётся в кэш', () async {
    PhotoCache.client = MockClient((_) async => http.Response('', 404));
    expect(await PhotoCache.bytes('https://x.example/404.jpg'), isNull);
    expect(dir.listSync(), isEmpty);
  });

  test('больше лимита — старые удаляются', () async {
    final big = Uint8List(PhotoCache.maxBytes ~/ 2 - 10);
    PhotoCache.client = MockClient((_) async => http.Response.bytes(big, 200));
    await PhotoCache.bytes('https://x.example/1.jpg');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await PhotoCache.bytes('https://x.example/2.jpg');
    await PhotoCache.bytes('https://x.example/3.jpg');
    final total = dir.listSync().whereType<File>().fold<int>(0, (a, f) => a + f.lengthSync());
    expect(total, lessThanOrEqualTo(PhotoCache.maxBytes));
    expect(dir.listSync().length, 2);
  });
}
