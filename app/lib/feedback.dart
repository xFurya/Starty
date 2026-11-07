// Обратная связь: ошибка, идея или что-то ещё — прямо из приложения на наш сервер (Supabase,
// tools/feedback/schema.sql, функция send_feedback). Без почты и браузера: человек не уходит из приложения.
// Владелец читает сообщения в панели Supabase: Table Editor → feedback.
//
// Вместе с текстом уходит только то, что названо на странице: версия приложения, система и, если
// сообщение начато из карточки старта или профиля, к чему оно относится. Контакт — только если его ввели.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'sync.dart' show syncConfigured, syncKey, syncUrl;
import 'update.dart' show appBuild, appVersion;

enum FeedbackKind { bug, idea, other }

/// Предел текста в приложении (сервер принимает до 4000 — с запасом на будущее).
const feedbackMax = 2000;

/// Предел контакта — как на сервере.
const feedbackContactMax = 200;

/// Сервер есть в сборке — есть и обратная связь. Нет — так и сказано в настройках.
bool get feedbackAvailable => syncConfigured;

/// Система для сервера: android, ios, windows, macos, web.
String get feedbackPlatform {
  if (kIsWeb) return 'web';
  return switch (defaultTargetPlatform) {
    TargetPlatform.android => 'android',
    TargetPlatform.iOS => 'ios',
    TargetPlatform.windows => 'windows',
    TargetPlatform.macOS => 'macos',
    TargetPlatform.linux => 'linux',
    TargetPlatform.fuchsia => 'fuchsia',
  };
}

/// Что уходит вместе с сообщением — словами для человека: «1.0.63, Android».
String feedbackSystemLine([String? platform]) {
  final name = switch (platform ?? feedbackPlatform) {
    'android' => 'Android',
    'ios' => 'iOS',
    'windows' => 'Windows',
    'macos' => 'macOS',
    'web' => 'браузер',
    final other => other,
  };
  return '$appVersion, $name';
}

/// Ответы сервера (tools/feedback/schema.sql) — человеческими словами.
const feedbackErrors = {
  'bad_kind': 'Сервер не принял сообщение',
  'empty_message': 'Напишите сообщение',
  'long_message': 'Сообщение слишком длинное',
  'feedback_busy': 'Сейчас слишком много сообщений, попробуйте через несколько минут',
};

/// Отправить сообщение. null — дошло до сервера; иначе — что помешало, для человека.
/// [about] — к чему относится: `start:<id>` или `profile:<имя>`; пусто — из настроек.
/// Повтор того же текста после «Сервер не отвечает» сервер не записывает второй раз.
Future<String?> sendFeedback({
  required FeedbackKind kind,
  required String message,
  String contact = '',
  String about = '',
  http.Client? client,
  String url = syncUrl,
  String key = syncKey,
  String? platform,
}) async {
  final text = message.trim();
  if (text.isEmpty) return feedbackErrors['empty_message'];
  if (text.runes.length > feedbackMax) return feedbackErrors['long_message'];
  if (url.isEmpty || key.isEmpty) return 'Обратная связь недоступна в этой сборке';
  final c = client ?? http.Client();
  try {
    final r = await c
        .post(
          Uri.parse('$url/rest/v1/rpc/send_feedback'),
          headers: {'apikey': key, 'Authorization': 'Bearer $key', 'Content-Type': 'application/json'},
          body: jsonEncode({
            'kind': kind.name,
            'message': text,
            'contact': contact.trim().isEmpty ? null : contact.trim(),
            'about': about.isEmpty ? null : about,
            'app_version': '$appVersion+$appBuild',
            'platform': platform ?? feedbackPlatform,
          }),
        )
        .timeout(const Duration(seconds: 20));
    if (r.statusCode >= 200 && r.statusCode < 300) return null;
    // функции на сервере ещё нет — схему не выполнили
    if (r.statusCode == 404) return 'Сервер пока не принимает сообщения';
    var msg = '';
    try {
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      if (j is Map) msg = '${j['message'] ?? ''}';
    } catch (_) {}
    if (feedbackErrors[msg] case final m?) return m;
    if (r.statusCode == 429) return feedbackErrors['feedback_busy'];
    return 'Сервер ответил ошибкой (${r.statusCode})';
  } on TimeoutException {
    return 'Сервер не отвечает';
  } catch (_) {
    return 'Нет связи с сервером';
  } finally {
    if (client == null) c.close();
  }
}
