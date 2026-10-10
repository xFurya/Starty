// Самообновление — как у Дневника. На Android всё делает нативная сторона
// (Updater.kt): раз в час и при открытии смотрит сайт, скачивает, сверяет и ставит
// сама, как только приложение свернут. Здесь — только честно показать, что
// происходит. На iPhone обновления приходят через SideStore; приложение лишь
// говорит, что вышла новая версия (version.json).
import 'dart:async';
import 'dart:convert';
import 'dart:io' show exit;
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'desktop_updater.dart';
import 'platform.dart';
import 'update.dart';

class UpdateState {
  final bool enabled;
  final String current;
  final bool checking;
  final DateTime? checkedAt;
  final String error;
  final String? downloading;
  final int progress; // процентов скачано
  final String? readyVersion, readyNotes;
  final String wait; // leave — после сворачивания, confirm — ждёт подтверждения
  final bool stuck;
  final bool canInstall; // разрешена ли приложению установка приложений
  final String installError;
  final String? updatedVersion, updatedNotes;
  final bool desktop; // компьютер: ставится при закрытии

  const UpdateState({
    this.enabled = true,
    this.current = appVersion,
    this.checking = false,
    this.checkedAt,
    this.error = '',
    this.downloading,
    this.progress = 0,
    this.readyVersion,
    this.readyNotes,
    this.wait = '',
    this.stuck = false,
    this.canInstall = true,
    this.installError = '',
    this.updatedVersion,
    this.updatedNotes,
    this.desktop = false,
  });

  factory UpdateState.fromJson(Map<String, dynamic> j) {
    final ready = j['ready'] as Map?;
    final updated = j['updated'] as Map?;
    return UpdateState(
      enabled: j['enabled'] != false,
      current: (j['current'] as String?)?.isNotEmpty == true ? j['current'] : appVersion,
      checking: j['checking'] == true,
      checkedAt: j['checkedAt'] is int ? DateTime.fromMillisecondsSinceEpoch(j['checkedAt']) : null,
      error: (j['error'] as String?) ?? '',
      downloading: j['downloading'] as String?,
      progress: (j['progress'] as int?) ?? 0,
      readyVersion: ready?['version'] as String?,
      readyNotes: ready?['notes'] as String?,
      wait: (j['wait'] as String?) ?? '',
      stuck: j['stuck'] == true,
      canInstall: j['canInstall'] != false,
      installError: (j['installError'] as String?) ?? '',
      updatedVersion: updated?['version'] as String?,
      updatedNotes: updated?['notes'] as String?,
    );
  }

  bool get ready => readyVersion != null && readyVersion!.isNotEmpty;

  /// Скачанное не встанет само: нужен человек (подтверждение, разрешение, сбой).
  bool get needsHand => ready && (wait == 'confirm' || !canInstall || installError.isNotEmpty || stuck);

  /// Показанная строка — про неполадку (красным), а не про ход дела. Совпадает с порядком в line():
  /// пока идёт загрузка или проверка, прошлая ошибка не в счёт.
  bool get problem {
    if (!enabled) return false;
    if (downloading != null && !ready) return false;
    if (ready) return needsHand;
    if (checking) return false;
    return error.isNotEmpty;
  }

  /// Строка состояния для настроек — то, что есть на самом деле.
  String line(DateTime now) {
    if (!enabled) return 'Недоступно';
    if (downloading != null && !ready) return 'Скачивается версия $downloading · $progress %';
    if (ready) {
      final v = 'Версия $readyVersion';
      if (wait == 'confirm') return '$v ждёт подтверждения установки';
      if (!canInstall) return '$v скачана · нет разрешения на установку';
      // сырое системное сообщение (часто английское) не показываем: ниже есть «Открыть установщик»
      if (installError.isNotEmpty) return '$v не установилась';
      if (stuck) return '$v не установилась автоматически';
      if (desktop) return '$v скачана · установится при закрытии';
      return '$v скачана · установится после сворачивания';
    }
    if (checking) return 'Проверка…';
    if (error.isNotEmpty) return 'Ошибка проверки · $error';
    final at = checkedAt;
    return at == null ? 'Устанавливаются автоматически' : 'Устанавливаются автоматически · проверено ${ago(at, now)}';
  }
}

/// «только что», «5 мин назад», «2 ч назад», «3 дн назад».
String ago(DateTime t, DateTime now) {
  final d = now.difference(t);
  if (d.inMinutes < 1) return 'только что';
  if (d.inHours < 1) return '${d.inMinutes} мин назад';
  if (d.inDays < 1) return '${d.inHours} ч назад';
  return '${d.inDays} дн назад';
}

class Updates extends ChangeNotifier {
  Updates._();
  static final instance = Updates._();
  static const _ch = MethodChannel('starty/update');

  /// Нативное самообновление есть только на Android.
  static bool get native => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Windows и macOS: самообновление на стороне Dart (desktop_updater.dart).
  static bool get desktop => isDesktop;

  /// Приложение обновляет себя само (Android, Windows, macOS); iPhone — через SideStore.
  static bool get managed => native || desktop;

  DesktopUpdater? _desk;
  // ignore: unused_field
  Timer? _deskTimer;
  // ignore: unused_field
  AppLifecycleListener? _exitHook;

  /// Android: состояние самообновления; null — ещё не получено.
  UpdateState? state;

  /// iPhone: вышедшая версия из version.json (ставится через SideStore).
  UpdateInfo? available;

  /// Однократные сообщения для ленты: «обновлено до …» и «вышла версия …».
  String? updatedMessage;
  String? readyAnnounced;

  bool _started = false;

  Future<void> init() async {
    if (_started) return;
    _started = true;
    if (native) {
      _ch.setMethodCallHandler((call) async {
        if (call.method == 'changed') _apply(call.arguments as String?);
      });
      try {
        _apply(await _ch.invokeMethod<String>('status'));
      } catch (_) {}
    } else if (desktop) {
      final d = _desk = DesktopUpdater((st) {
        state = st;
        notifyListeners();
      });
      // закрытие окна — момент для установки: скрипт дождётся выхода и заменит файлы
      _exitHook = AppLifecycleListener(onExitRequested: () async {
        if (d.ready) await d.install(relaunch: false);
        return AppExitResponse.exit;
      });
      _deskTimer = Timer.periodic(const Duration(hours: 1), (_) => d.check());
      unawaited(d.check());
    } else if (isIos) {
      available = await checkUpdate();
      notifyListeners();
    }
    await _sayUpdated();
  }

  void _apply(String? json) {
    if (json == null) return;
    try {
      state = UpdateState.fromJson(Map<String, dynamic>.from(jsonDecode(json) as Map));
      notifyListeners();
    } catch (_) {}
  }

  /// Первый запуск новой версии — один раз сказать, что изменилось.
  Future<void> _sayUpdated() async {
    try {
      final p = await SharedPreferences.getInstance();
      final current = state?.current ?? appVersion;
      final seen = p.getString('seenVersion');
      if (seen != current) {
        if (seen != null) {
          final s = state;
          var notes = s != null && s.updatedVersion == current ? (s.updatedNotes ?? '') : '';
          if (desktop) notes = p.getString('deskNotes:$current') ?? '';
          updatedMessage = 'Фигурное катание обновлено до $current${notes.isNotEmpty ? '. $notes' : ''}';
          notifyListeners();
        }
        await p.setString('seenVersion', current);
      }
    } catch (_) {}
  }

  /// Сообщение «вышла версия …» — один раз на версию.
  String? takeReadyNotice() {
    final s = state;
    if (s == null || !s.ready || readyAnnounced == s.readyVersion) return null;
    readyAnnounced = s.readyVersion;
    if (s.needsHand) return 'Обновление ${s.readyVersion} ждёт установки';
    return 'Версия ${s.readyVersion} скачана';
  }

  String? takeUpdatedMessage() {
    final m = updatedMessage;
    updatedMessage = null;
    return m;
  }

  Future<void> check() async {
    if (desktop) return _desk?.check();
    if (!native) return;
    try {
      await _ch.invokeMethod('check');
    } catch (_) {}
  }

  /// «Обновить сейчас»: приложение закроется, открыть снова — из уведомления.
  Future<String> installNow() async {
    if (desktop) {
      final d = _desk;
      if (d != null && await d.install(relaunch: true)) exit(0);
      return '';
    }
    if (!native) return '';
    try {
      return await _ch.invokeMethod<String>('install') ?? '';
    } catch (e) {
      return '$e';
    }
  }

  /// Запасной путь — обычный системный установщик.
  Future<void> openInstaller() async {
    if (!native) return;
    try {
      await _ch.invokeMethod('openInstaller');
    } catch (_) {}
  }

  /// Системный экран «Установка неизвестных приложений» для этого приложения.
  Future<void> allowInstall() async {
    if (!native) return;
    try {
      await _ch.invokeMethod('allowInstall');
    } catch (_) {}
  }
}
