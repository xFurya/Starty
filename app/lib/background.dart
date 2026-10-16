// Фоновое обновление (Android раз в 3 часа, iPhone — когда его будит система): раз в несколько часов подтянуть расписание и
// переставить уведомления — новые старты, сдвиги времени и время выхода наших
// появляются, когда приложение может быть закрыто.
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import 'data.dart';
import 'reminders.dart';

/// Расписание для напоминаний: региональные старты — только если показ включён (как в ленте), затем под отслеживаемых.
Schedule remindersSchedule(Schedule raw, {required bool regional, required Follow follow}) {
  final shown = regional ? raw : raw.withStarts([for (final s in raw.starts) if (!s.regional) s]);
  return shown.withFollow(follow);
}

@pragma('vm:entry-point')
void backgroundDispatcher() {
  Workmanager().executeTask((task, input) async {
    try {
      WidgetsFlutterBinding.ensureInitialized();
      await Prefs.init();
      await Reminders.init();
      final raw = await Repo.fetch() ?? await Repo.cached();
      final data = raw == null ? null : remindersSchedule(raw, regional: Prefs.regional, follow: Prefs.followOr(raw.watchlist));
      await Reminders.sync(data, NotifyPlan(NotifyRules.fromJson(Prefs.rulesJson), Prefs.forcedOn, Prefs.forcedOff));
    } catch (_) {}
    return true;
  });
}

Future<void> scheduleBackground() async {
  if (kIsWeb || defaultTargetPlatform == TargetPlatform.windows || defaultTargetPlatform == TargetPlatform.macOS) return;
  try {
    await Workmanager().initialize(backgroundDispatcher);
    if (defaultTargetPlatform == TargetPlatform.android) {
      await Workmanager().registerPeriodicTask(
        'refresh',
        'refresh',
        frequency: const Duration(hours: 3),
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      );
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      // iOS запускает не чаще, чем сам решит (обычно несколько раз в сутки); идентификатор — как в Info.plist
      await Workmanager().registerPeriodicTask('refresh', 'refresh', initialDelay: const Duration(hours: 3));
    }
  } catch (_) {}
}
