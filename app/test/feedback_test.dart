import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:starty/feedback.dart';

const _url = 'https://x.supabase.co';
const _key = 'k';

/// Ответ сервера с JSON-телом в UTF-8.
http.Response _reply(String body, int status) => http.Response.bytes(
  utf8.encode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

/// Вызов с явными параметрами, чтобы тесты не зависели от defines сборки.
Future<String?> _send(
  http.Client client, {
  String message = 'Не открывается протокол',
  String contact = '',
  String about = '',
  String url = _url,
}) => sendFeedback(
  kind: FeedbackKind.bug,
  message: message,
  contact: contact,
  about: about,
  client: client,
  url: url,
  key: _key,
  platform: 'android',
);

void main() {
  group('отправка обратной связи', () {
    test('успех: POST на функцию, заголовки и тело с обрезанными полями', () async {
      late http.Request req;
      final client = MockClient((r) async {
        req = r;
        return _reply('5', 200);
      });

      final err = await _send(
        client,
        message: '  Не открывается протокол  ',
        contact: ' @me ',
        about: 'start:abc',
      );

      expect(err, isNull);
      expect(req.method, 'POST');
      expect(req.url.toString(), 'https://x.supabase.co/rest/v1/rpc/send_feedback');
      expect(req.headers['apikey'], 'k');
      expect(req.headers['Authorization'], 'Bearer k');

      final body = jsonDecode(utf8.decode(req.bodyBytes)) as Map<String, dynamic>;
      expect(body['kind'], 'bug');
      expect(body['message'], 'Не открывается протокол');
      expect(body['contact'], '@me');
      expect(body['about'], 'start:abc');
      expect(body['platform'], 'android');
      expect(body['app_version'], isA<String>());
      expect(body['app_version'] as String, isNotEmpty);
      expect(body['app_version'] as String, contains('+'));
    });

    test('пустые контакт и «к чему» уходят как null, а не пустые строки', () async {
      late Map<String, dynamic> body;
      final client = MockClient((r) async {
        body = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
        return _reply('5', 200);
      });

      final err = await _send(client, contact: '   ', about: '');

      expect(err, isNull);
      expect(body.containsKey('contact'), isTrue);
      expect(body['contact'], isNull);
      expect(body.containsKey('about'), isTrue);
      expect(body['about'], isNull);
    });

    test('пустое сообщение — подсказка, и запроса на сервер нет', () async {
      var calls = 0;
      final client = MockClient((r) async {
        calls++;
        return _reply('5', 200);
      });

      final err = await _send(client, message: '   ');

      expect(err, 'Напишите сообщение');
      expect(calls, 0);
    });

    test('сообщение длиннее предела — подсказка, и запроса на сервер нет', () async {
      var calls = 0;
      final client = MockClient((r) async {
        calls++;
        return _reply('5', 200);
      });
      final tooLong = List.filled(feedbackMax + 1, 'я').join();

      final err = await _send(client, message: tooLong);

      expect(err, 'Сообщение слишком длинное');
      expect(calls, 0);
    });

    test('404 — сервер пока не принимает сообщения', () async {
      final client = MockClient((r) async => _reply('', 404));

      expect(await _send(client), 'Сервер пока не принимает сообщения');
    });

    test('400 с feedback_busy — текст из таблицы ответов сервера', () async {
      final client = MockClient(
        (r) async => _reply('{"code":"22023","message":"feedback_busy"}', 400),
      );

      expect(await _send(client), feedbackErrors['feedback_busy']);
    });

    test('400 с bad_kind — «Сервер не принял сообщение»', () async {
      final client = MockClient(
        (r) async => _reply('{"code":"22023","message":"bad_kind"}', 400),
      );

      expect(await _send(client), 'Сервер не принял сообщение');
    });

    test('500 с нечитаемым телом — ошибка с кодом статуса', () async {
      final client = MockClient(
        (r) async => http.Response.bytes(utf8.encode('oops'), 500),
      );

      expect(await _send(client), 'Сервер ответил ошибкой (500)');
    });

    test('клиент бросает исключение — «Нет связи с сервером»', () async {
      final client = MockClient((r) async {
        throw http.ClientException('x');
      });

      expect(await _send(client), 'Нет связи с сервером');
    });

    test('адрес сервера пуст — сборка без обратной связи, запроса нет', () async {
      var calls = 0;
      final client = MockClient((r) async {
        calls++;
        return _reply('5', 200);
      });

      final err = await _send(client, url: '');

      expect(err, 'Обратная связь недоступна в этой сборке');
      expect(calls, 0);
    });

    test('строка о системе: браузер для web, iOS для ios', () {
      expect(feedbackSystemLine('web'), endsWith(', браузер'));
      expect(feedbackSystemLine('ios'), endsWith(', iOS'));
    });
  });
}
