// Проверка новой версии приложения: version.json рядом с расписанием.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'main.dart';

/// Номер этой сборки; растёт с каждой выкладкой.
const appBuild = int.fromEnvironment('BUILD', defaultValue: 1);

/// Версия для показа; на Android точная — из установленного пакета (updater.dart).
const appVersion = String.fromEnvironment('VERSION', defaultValue: '1.0.2');
const versionUrl = 'https://xfurya.github.io/Starty/app/version.json';

class UpdateInfo {
  final String url, note;
  UpdateInfo(this.url, this.note);
}

Future<UpdateInfo?> checkUpdate() async {
  try {
    final r = await http
        .get(Uri.parse('$versionUrl?t=${DateTime.now().millisecondsSinceEpoch ~/ 3600000}'))
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) return null;
    final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    final key = defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';
    final v = j[key] as Map<String, dynamic>?;
    if (v == null || (v['build'] as int) <= appBuild) return null;
    return UpdateInfo(v['url'] as String, (v['note'] as String?) ?? '');
  } catch (_) {
    return null;
  }
}

class UpdateBar extends StatelessWidget {
  final UpdateInfo info;
  final VoidCallback onClose;
  const UpdateBar({super.key, required this.info, required this.onClose});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
      decoration: BoxDecoration(
        color: p.frost,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.plateLine),
      ),
      child: Row(
        children: [
          Icon(Icons.arrow_circle_down_rounded, size: 20, color: p.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Новая версия',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: p.ink),
            ),
          ),
          TextButton(
            onPressed: () => launchUrl(Uri.parse(info.url), mode: LaunchMode.externalApplication),
            style: TextButton.styleFrom(
              foregroundColor: p.accent,
              textStyle: const TextStyle(fontFamily: 'Manrope', fontSize: 14.5, fontWeight: FontWeight.w700),
            ),
            child: const Text('Обновить'),
          ),
          IconButton(
            tooltip: 'Закрыть',
            onPressed: onClose,
            icon: Icon(Icons.close, size: 18, color: p.ink2),
          ),
        ],
      ),
    );
  }
}
