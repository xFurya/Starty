// Фото спортсменов на диске: найденное фото не пропадает без сети и после перезапуска.
// Файлы лежат в папке приложения под хэшем адреса, всего не больше 30 МБ: старые (по последнему
// обращению) удаляются. Без папки (веб, нет плагина) работает как обычная загрузка по сети.
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class PhotoCache {
  /// Клиент и папка подменяются в тестах.
  static http.Client client = http.Client();
  static Directory? dirOverride;
  static const maxBytes = 30 * 1024 * 1024;

  static final Map<String, Uint8List> _mem = {};
  static final Map<String, Future<Uint8List?>> _busy = {};
  static Directory? _dir;

  static Future<Directory?> _folder() async {
    if (dirOverride != null) return dirOverride;
    if (kIsWeb) return null;
    if (_dir != null) return _dir;
    try {
      final d = Directory(
        '${(await getApplicationSupportDirectory()).path}/photos',
      );
      await d.create(recursive: true);
      return _dir = d;
    } catch (_) {
      return null;
    }
  }

  static String _name(String url) => md5.convert(url.codeUnits).toString();

  /// Сначала память, потом диск, потом сеть (с записью на диск). Нет нигде — null.
  static Future<Uint8List?> bytes(String url) {
    final m = _mem[url];
    if (m != null) return Future.value(m);
    return _busy[url] ??= _load(url).whenComplete(() {
      _busy.remove(url);
    });
  }

  static Future<Uint8List?> _load(String url) async {
    final dir = await _folder();
    final file = dir == null ? null : File('${dir.path}/${_name(url)}');
    try {
      if (file != null && await file.exists()) {
        final b = await file.readAsBytes();
        if (b.isNotEmpty) {
          _mem[url] = b;
          try {
            await file.setLastModified(DateTime.now());
          } catch (_) {}
          return b;
        }
      }
    } catch (_) {}
    try {
      final r = await client.get(Uri.parse(url));
      if (r.statusCode != 200 || r.bodyBytes.isEmpty) return null;
      final b = r.bodyBytes;
      _mem[url] = b;
      if (file != null) {
        try {
          await file.writeAsBytes(b, flush: true);
          await _trim(dir!);
        } catch (_) {}
      }
      return b;
    } catch (_) {
      return null;
    }
  }

  /// Не больше [maxBytes]: удаляем самые давно открытые.
  static Future<void> _trim(Directory dir) async {
    final files = <(File, int, DateTime)>[];
    var sum = 0;
    await for (final e in dir.list()) {
      if (e is! File) continue;
      final st = await e.stat();
      files.add((e, st.size, st.modified));
      sum += st.size;
    }
    if (sum <= maxBytes) return;
    files.sort((a, b) => a.$3.compareTo(b.$3));
    for (final f in files) {
      if (sum <= maxBytes) break;
      try {
        await f.$1.delete();
        sum -= f.$2;
      } catch (_) {}
    }
  }

  /// Только для тестов: забыть память.
  @visibleForTesting
  static void resetMemory() {
    _mem.clear();
    _busy.clear();
    _dir = null;
  }
}

/// Фото из кэша на диске. Пока нет байтов или фото нет — ничего не рисует (под ним запасной вариант).
class CachedPhoto extends StatefulWidget {
  final String url;
  final Widget fallback;
  final Alignment alignment;
  const CachedPhoto({
    super.key,
    required this.url,
    required this.fallback,
    this.alignment = Alignment.center,
  });

  @override
  State<CachedPhoto> createState() => _CachedPhotoState();
}

class _CachedPhotoState extends State<CachedPhoto> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb) _fetch();
  }

  @override
  void didUpdateWidget(CachedPhoto old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url && !kIsWeb) {
      _bytes = null;
      _fetch();
    }
  }

  Future<void> _fetch() async {
    final url = widget.url;
    final b = await PhotoCache.bytes(url);
    if (mounted && url == widget.url && b != null) setState(() => _bytes = b);
  }

  @override
  Widget build(BuildContext context) {
    // в вебе картинку грузит сам браузер (без CORS-запроса), кэш у него свой
    if (kIsWeb) {
      return Image.network(
        widget.url,
        fit: BoxFit.cover,
        alignment: widget.alignment,
        errorBuilder: (c, e, st) => widget.fallback,
      );
    }
    final b = _bytes;
    if (b == null) return const SizedBox.expand();
    return Image.memory(
      b,
      fit: BoxFit.cover,
      alignment: widget.alignment,
      filterQuality: FilterQuality.medium,
      gaplessPlayback: true,
      errorBuilder: (c, e, st) => widget.fallback,
      frameBuilder: (c, child, frame, sync) => sync
          ? child
          : AnimatedOpacity(
              opacity: frame == null ? 0 : 1,
              duration: const Duration(milliseconds: 250),
              child: child,
            ),
    );
  }
}
