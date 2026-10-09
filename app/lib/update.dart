// Проверка новой версии приложения: version.json рядом с расписанием.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'main.dart';

/// Номер этой сборки; растёт с каждой выкладкой.
const appBuild = int.fromEnvironment('BUILD', defaultValue: 1);
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
      padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
      decoration: BoxDecoration(color: p.accent.withValues(alpha: .12), borderRadius: BorderRadius.circular(14)),
      child: Row(
        children: [
          Expanded(
            child: Text(
              info.note.isEmpty ? 'Есть новая версия приложения' : info.note,
              style: TextStyle(fontSize: 14.5, color: p.ink),
            ),
          ),
          TextButton(
            onPressed: () => launchUrl(Uri.parse(info.url), mode: LaunchMode.externalApplication),
            child: const Text('Обновить'),
          ),
          IconButton(
            onPressed: onClose,
            icon: Icon(Icons.close, size: 18, color: p.ink3),
          ),
        ],
      ),
    );
  }
}
