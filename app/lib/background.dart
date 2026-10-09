// Фоновое обновление (Android): раз в несколько часов подтянуть расписание и
// переставить уведомления — время выхода спортсменов появляется после жеребьёвки,
// когда приложение может быть закрыто.
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import 'data.dart';
import 'reminders.dart';

@pragma('vm:entry-point')
void backgroundDispatcher() {
  Workmanager().executeTask((task, input) async {
    try {
      WidgetsFlutterBinding.ensureInitialized();
      await Prefs.init();
      await Reminders.init();
      final data = await Repo.fetch() ?? await Repo.cached();
      await Reminders.sync(data, Prefs.watched, Prefs.followed);
    } catch (_) {}
    return true;
  });
}

Future<void> scheduleBackground() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  try {
    await Workmanager().initialize(backgroundDispatcher);
    await Workmanager().registerPeriodicTask(
      'refresh',
      'refresh',
      frequency: const Duration(hours: 3),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
  } catch (_) {}
}
