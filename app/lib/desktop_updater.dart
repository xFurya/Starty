// Самообновление на компьютере (Windows, macOS): раз в час и при запуске смотрим
// site/app/latest.json, скачиваем архив своей платформы, сверяем размер и sha256 и
// ставим при закрытии приложения (или по кнопке «Обновить сейчас», с перезапуском).
// Замену файлов делает отдельный короткий скрипт — приложение не может заменить само себя.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'platform.dart';
import 'update.dart';
import 'updater.dart';

const _latestUrl = 'https://xfurya.github.io/Starty/app/latest.json';

class DesktopUpdater {
  DesktopUpdater(this.onState);
  final void Function(UpdateState) onState;

  bool _busy = false, _checking = false;
  DateTime? _checkedAt;
  String _error = '';
  String? _downloading;
  int _progress = 0;
  String? _readyVersion, _readyNotes;
  File? _readyZip;

  UpdateState get snapshot => UpdateState(
    desktop: true,
    checking: _checking,
    checkedAt: _checkedAt,
    error: _error,
    downloading: _downloading,
    progress: _progress,
    readyVersion: _readyVersion,
    readyNotes: _readyNotes,
  );

  bool get ready => _readyZip != null;

  void _push() => onState(snapshot);

  Directory get _dir => Directory('${Directory.systemTemp.path}${Platform.pathSeparator}starty-update');

  Future<void> check() async {
    if (_busy) return;
    _busy = true;
    _checking = true;
    _error = '';
    _push();
    try {
      await _run();
    } on TimeoutException {
      _error = 'нет связи';
    } on SocketException {
      _error = 'нет связи';
    } on http.ClientException {
      _error = 'нет связи';
    } catch (_) {
      _error = 'сбой';
    } finally {
      _busy = false;
      _checking = false;
      _downloading = null;
      _checkedAt = DateTime.now();
      _push();
    }
  }

  Future<void> _run() async {
    final r = await http
        .get(Uri.parse('$_latestUrl?t=${DateTime.now().millisecondsSinceEpoch ~/ 60000}'))
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw const SocketException('http');
    final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    final e = j[isWindows ? 'windows' : 'macos'] as Map<String, dynamic>?;
    final code = j['code'] as int? ?? 0;
    if (e == null || e['code'] != code || code <= appBuild) {
      _readyZip = null;
      _readyVersion = null;
      _readyNotes = null;
      if (await _dir.exists()) await _dir.delete(recursive: true);
      return;
    }
    final version = j['version'] as String;
    final size = e['size'] as int;
    final sha = (e['sha256'] as String).toLowerCase();
    await _dir.create(recursive: true);
    final name = sha.substring(0, 12);
    final done = File('${_dir.path}${Platform.pathSeparator}$name.zip');
    final part = File('${_dir.path}${Platform.pathSeparator}$name.part');
    // остальные скачанные версии больше не нужны
    await for (final f in _dir.list()) {
      if (f.path != done.path && f.path != part.path) await f.delete(recursive: true);
    }
    if (!(await done.exists() && await _valid(done, size, sha))) {
      if (await done.exists()) await done.delete();
      _downloading = version;
      _progress = 0;
      _push();
      await _download(e['url'] as String, part, size);
      if (!await _valid(part, size, sha)) {
        await part.delete();
        throw StateError('hash');
      }
      await part.rename(done.path);
    }
    _readyZip = done;
    _readyVersion = version;
    _readyNotes = (j['notes'] as String?) ?? '';
  }

  Future<bool> _valid(File f, int size, String sha) async {
    if (await f.length() != size) return false;
    final d = await sha256.bind(f.openRead()).first;
    return d.toString() == sha;
  }

  /// Докачка с места обрыва: до 5 попыток, 60 с без данных — обрыв.
  Future<void> _download(String url, File part, int size) async {
    var failures = 0;
    while (true) {
      final have = await part.exists() ? await part.length() : 0;
      if (have == size) return;
      if (have > size) await part.delete();
      final c = http.Client();
      try {
        final req = http.Request('GET', Uri.parse(url));
        final from = await part.exists() ? await part.length() : 0;
        if (from > 0) req.headers['Range'] = 'bytes=$from-';
        final res = await c.send(req).timeout(const Duration(seconds: 30));
        if (res.statusCode != 200 && res.statusCode != 206) throw const SocketException('http');
        final append = res.statusCode == 206 && from > 0;
        final sink = part.openWrite(mode: append ? FileMode.append : FileMode.write);
        var got = append ? from : 0;
        var shown = -1;
        try {
          await for (final chunk in res.stream.timeout(const Duration(seconds: 60))) {
            sink.add(chunk);
            got += chunk.length;
            final pct = size == 0 ? 0 : (got * 100 ~/ size).clamp(0, 100);
            if (pct != shown) {
              shown = pct;
              _progress = pct;
              _push();
            }
          }
        } finally {
          await sink.close();
        }
        return;
      } catch (_) {
        if (++failures >= 5) rethrow;
        await Future<void>.delayed(Duration(seconds: failures * 2));
      } finally {
        c.close();
      }
    }
  }

  bool _spawned = false;

  /// Запустить замену файлов. relaunch — открыть приложение снова; иначе (закрытие) оно просто закрылось.
  Future<bool> install({required bool relaunch}) async {
    final zip = _readyZip;
    if (zip == null || _spawned) return false;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('deskNotes:$_readyVersion', _readyNotes ?? '');
      final exe = Platform.resolvedExecutable;
      final sep = Platform.pathSeparator;
      if (isWindows) {
        final dir = exe.substring(0, exe.lastIndexOf(sep));
        final script = File('${_dir.path}${sep}apply.ps1');
        await script.writeAsBytes([0xEF, 0xBB, 0xBF, ...utf8.encode(_windowsScript)]);
        await Process.start(
          'powershell.exe',
          [
            '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass',
            '-File', script.path,
            '-AppPid', '$pid', '-Zip', zip.path, '-Dir', dir, '-Exe', exe, '-Relaunch', relaunch ? '1' : '0',
          ],
          mode: ProcessStartMode.detached,
        );
      } else {
        // .../Starty.app/Contents/MacOS/starty → .../Starty.app
        final app = File(exe).parent.parent.parent.path;
        final script = File('${_dir.path}${sep}apply.sh');
        await script.writeAsString(_macScript);
        await Process.start('/bin/sh', [script.path, '$pid', zip.path, app, relaunch ? '1' : '0'],
            mode: ProcessStartMode.detached);
      }
      _spawned = true;
      return true;
    } catch (_) {
      return false;
    }
  }
}

const _windowsScript = r'''
param([int]$AppPid, [string]$Zip, [string]$Dir, [string]$Exe, [int]$Relaunch)
try { Wait-Process -Id $AppPid -Timeout 90 -ErrorAction SilentlyContinue } catch {}
$stage = Join-Path ([IO.Path]::GetTempPath()) 'starty-stage'
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
$ok = $false
try {
  Expand-Archive -LiteralPath $Zip -DestinationPath $stage -Force
  for ($i = 0; $i -lt 15 -and -not $ok; $i++) {
    try {
      Copy-Item -Path (Join-Path $stage '*') -Destination $Dir -Recurse -Force -ErrorAction Stop
      $ok = $true
    } catch { Start-Sleep -Seconds 1 }
  }
} catch {}
if ($ok) { Remove-Item -LiteralPath $Zip -Force -ErrorAction SilentlyContinue }
Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
if ($Relaunch -eq 1) { Start-Process -FilePath $Exe }
''';

const _macScript = r'''#!/bin/sh
PID="$1"; ZIP="$2"; APP="$3"; RELAUNCH="$4"
i=0
while kill -0 "$PID" 2>/dev/null && [ "$i" -lt 180 ]; do sleep 0.5; i=$((i+1)); done
STAGE=$(mktemp -d)
if ditto -x -k "$ZIP" "$STAGE" && [ -d "$STAGE/Starty.app" ]; then
  rm -rf "$APP.old"
  if mv "$APP" "$APP.old"; then
    if mv "$STAGE/Starty.app" "$APP"; then
      rm -rf "$APP.old"
      xattr -cr "$APP" 2>/dev/null
      rm -f "$ZIP"
    else
      mv "$APP.old" "$APP"
    fi
  fi
fi
rm -rf "$STAGE"
if [ "$RELAUNCH" = "1" ]; then open "$APP"; fi
''';
