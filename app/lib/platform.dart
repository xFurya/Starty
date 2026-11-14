// Какая это платформа. dart:io в вебе не трогаем.
import 'package:flutter/foundation.dart';

import 'board_proxy.dart';

bool get isWindows => !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
bool get isMac => !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
bool get isDesktop => isWindows || isMac;
bool get isIos => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
bool get isAndroid => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// Уведомления о стартах. В браузере их нет: напоминание в срок может прислать только свой сервер
/// рассылки, а его нет. Значит и обещать их на вебе нечего — ни переключателей, ни «запланировано».
bool get canNotify => !kIsWeb;

/// Табло турниров — чужие сайты: браузер не пустит к ним страницу без их разрешения. В веб-версии
/// табло читается через функцию нашего сервера (board_proxy.dart), если она выложена; нет её —
/// живые места и протокол только из файлов нашего сайта.
bool get canReadBoards => !kIsWeb || BoardProxy.active;
