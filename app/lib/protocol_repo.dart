// Файл протокола с сайта (GitHub Pages): загрузка, копия на устройстве и честные исходы.
// Кэш — в SharedPreferences: не больше восьми турниров, ошибочные файлы в кэш не пишем.
// Окончательный сегмент из кэша не заменяется промежуточным из свежей загрузки.
// Все операции с кэшем — в try/catch: без кэша экран работает.
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'data.dart';
import 'protocol_model.dart';

/// Исход загрузки файла протокола.
sealed class ProtocolLoad {
  const ProtocolLoad();
}

/// Файл получен и разобран.
final class ProtocolOk extends ProtocolLoad {
  final ProtocolDoc doc;
  final DateTime fetchedAt;
  const ProtocolOk(this.doc, this.fetchedAt);
}

/// Сети нет, таймаут или ошибка сервера. [cached] — последний удачный файл, если он есть.
final class ProtocolNetError extends ProtocolLoad {
  final ProtocolDoc? cached;
  final DateTime? cachedAt;
  const ProtocolNetError({this.cached, this.cachedAt});
}

/// Файла нет (404): турнир ещё не собран. [cached] — последний удачный файл, если он есть.
final class ProtocolMissing extends ProtocolLoad {
  final ProtocolDoc? cached;
  final DateTime? cachedAt;
  const ProtocolMissing({this.cached, this.cachedAt});
}

/// Файл пришёл, но не разобран целиком: не JSON, другая версия или нет обязательных полей.
/// [cached] — последний удачный файл, если он есть.
final class ProtocolFormatError extends ProtocolLoad {
  final String message;
  final ProtocolDoc? cached;
  final DateTime? cachedAt;
  const ProtocolFormatError(this.message, {this.cached, this.cachedAt});
}

class ProtocolRepo {
  /// Общий экземпляр приложения; в тестах — свой, с подменённым клиентом и часами.
  static ProtocolRepo app = ProtocolRepo();

  final http.Client _client;
  final DateTime Function() _now;

  ProtocolRepo({http.Client? client, DateTime Function()? now})
    : _client = client ?? http.Client(),
      _now = now ?? DateTime.now;

  /// Сколько турниров держим на устройстве.
  static const cacheLimit = 8;
  static const _lru = 'protocol.lru';
  static String _key(String proto) => 'protocol.file.$proto';

  /// Загрузка файла: сначала сеть (с минутной меткой, как расписание), при сбое — кэш.
  Future<ProtocolLoad> load(String proto) async {
    final url = protocolUrl(proto);
    if (url == null) return const ProtocolFormatError('имя файла');
    final cached = await _readCache(proto);
    final http.Response r;
    try {
      r = await _client
          .get(Uri.parse('$url?t=${_now().millisecondsSinceEpoch ~/ 60000}'), headers: {'Cache-Control': 'no-cache'})
          .timeout(const Duration(seconds: 15));
    } catch (_) {
      return _netError(cached);
    }
    if (r.statusCode == 404 || r.statusCode == 410) return ProtocolMissing(cached: cached?.doc, cachedAt: cached?.at);
    if (r.statusCode != 200) return _netError(cached);
    final String body;
    final ProtocolDoc fresh;
    try {
      body = utf8.decode(r.bodyBytes);
      fresh = ProtocolDoc.fromJsonString(body);
    } on FormatException catch (e) {
      return ProtocolFormatError(e.message, cached: cached?.doc, cachedAt: cached?.at);
    } on ProtocolFormatException catch (e) {
      return ProtocolFormatError(e.message, cached: cached?.doc, cachedAt: cached?.at);
    }
    final old = cached?.doc;
    final (merged, keptFinal) = old == null ? (fresh, false) : keepFinal(fresh, old);
    // при сохранённом окончательном сегменте кэш не перезаписываем промежуточным файлом
    if (!keptFinal) await _writeCache(proto, body);
    return ProtocolOk(merged, _now());
  }

  ProtocolNetError _netError(_Cached? cached) => ProtocolNetError(cached: cached?.doc, cachedAt: cached?.at);

  /// Окончательные сегменты и итоги из [old] сохраняются, если в [fresh] они промежуточные.
  /// Возвращает документ и флаг: сохранено хоть что-то из старого.
  static (ProtocolDoc, bool) keepFinal(ProtocolDoc fresh, ProtocolDoc old) {
    if (fresh.tid != old.tid) return (fresh, false);
    var kept = false;
    final cats = <ProtocolCategory>[];
    for (final c in fresh.categories) {
      final oc = old.categoryFor(c.kind, c.level);
      if (oc == null) {
        cats.add(c);
        continue;
      }
      final segs = <ProtocolSegment>[];
      for (final s in c.segments) {
        final os = oc.segmentOf(s.code);
        if (os != null && os.state == SegmentState.finalized && s.state != SegmentState.finalized) {
          segs.add(os);
          kept = true;
        } else {
          segs.add(s);
        }
      }
      var total = c.total;
      final ot = oc.total;
      if (ot != null && ot.state == TotalState.finalized && (total == null || total.state != TotalState.finalized)) {
        total = ot;
        kept = true;
      }
      cats.add(ProtocolCategory(kind: c.kind, level: c.level, name: c.name, segments: segs, total: total));
    }
    return (
      ProtocolDoc(
        v: fresh.v,
        tid: fresh.tid,
        tournament: fresh.tournament,
        src: fresh.src,
        built: fresh.built,
        marks: fresh.marks,
        categories: cats,
      ),
      kept,
    );
  }

  /// Последний удачный файл турнира с сохранённым временем; ошибка кэша — как пустой кэш.
  Future<_Cached?> _readCache(String proto) async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_key(proto));
      if (raw == null) return null;
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final doc = ProtocolDoc.fromJsonString(m['body'] as String);
      return _Cached(doc, DateTime.tryParse('${m['at']}'));
    } catch (_) {
      return null;
    }
  }

  /// Запись кэша с вытеснением: последние восемь турниров. Ошибка записи не мешает показу.
  Future<void> _writeCache(String proto, String body) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_key(proto), jsonEncode({'body': body, 'at': _now().toUtc().toIso8601String()}));
      final order = [proto, ...(p.getStringList(_lru) ?? const <String>[]).where((x) => x != proto)];
      for (final gone in order.skip(cacheLimit)) {
        await p.remove(_key(gone));
      }
      await p.setStringList(_lru, order.take(cacheLimit).toList());
    } catch (_) {}
  }
}

class _Cached {
  final ProtocolDoc doc;
  final DateTime? at;
  const _Cached(this.doc, this.at);
}
