// Какая это платформа. dart:io в вебе не трогаем.
import 'package:flutter/foundation.dart';

bool get isWindows => !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
bool get isMac => !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
bool get isDesktop => isWindows || isMac;
bool get isIos => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
bool get isAndroid => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
