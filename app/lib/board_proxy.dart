// Табло в браузере. Сайты табло не разрешают читать себя со страницы другого сайта (CORS), поэтому
// веб-версия ходит к ним через маленькую функцию на нашем сервере Supabase (tools/board/…/board):
// она забирает страницу табло и отдаёт её как есть, с разрешением для браузера. Пока функцию не
// выложили (404) — веб-версия, как раньше, читает файл протокола с сайта.
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import 'sync.dart' show syncUrl;

class BoardProxy {
  /// Адрес функции; пусто — в сборке нет сервера, прокси нет.
  static String get base => syncUrl.isEmpty ? '' : '$syncUrl/functions/v1/board';

  /// Работает ли функция: null — ещё не спрашивали, false — её нет (выложить не успели).
  static bool? up;

  /// Нужен ли прокси: только в браузере, только если сервер есть и функция не отказалась.
  static bool get active => kIsWeb && base.isNotEmpty && up != false;

  /// Адрес страницы табло для запроса из этой сборки.
  static String wrap(String url) => active ? '$base?u=${Uri.encodeComponent(url)}' : url;

  /// Заголовки запроса: в браузере — никаких (лишний заголовок потребовал бы предварительного
  /// запроса CORS), в приложении — просьба не отдавать копию из кэша.
  static Map<String, String>? get headers => kIsWeb ? null : const {'Cache-Control': 'no-cache'};

  /// По ответу видно, есть ли функция: она всегда ставит заголовок x-board.
  static void saw(http.Response r) {
    if (!active) return;
    if (r.headers.containsKey('x-board')) {
      up = true;
      _misses = 0;
    } else if (r.statusCode == 404) {
      up = false;
    }
  }

  static int _misses = 0;

  /// Запрос не прошёл вовсе. Ответ сервера на неизвестную функцию браузер может не показать (нет
  /// разрешения CORS) — тогда это исключение, а не 404: три подряд, пока функция ни разу не ответила, —
  /// считаем, что её нет, и веб-версия читает файл сайта.
  static void failed() {
    if (!active || up == true) return;
    if (++_misses >= 3) up = false;
  }
}
