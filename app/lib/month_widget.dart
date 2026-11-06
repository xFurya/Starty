// Виджет «Месяц» на рабочем столе Android (подписка): что ему показывать и куда открыть приложение по
// нажатию. Рисует его своя часть (packages/starty_widget, MonthWidget.kt); отсюда — только данные.
//
// Виджета нет в списке виджетов, пока нет подписки: его ставит сам человек — из списка или кнопкой
// на странице подписки. Поставленный остаётся и после подписки — тогда честно говорит, что входит в неё.
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:starty_widget/starty_widget.dart';

import 'billing.dart';
import 'data.dart';
import 'platform.dart';
import 'ui.dart';

/// Биты дня — как в MonthWidget.kt: виды стартов и полая точка (турнир без расписания).
const widgetWomen = 1, widgetMen = 2, widgetPairs = 4, widgetDance = 8, widgetOther = 16, widgetHollow = 32;

/// Дни месяца, как во вкладке «Месяц»: старты под фильтром — точкой своего вида, турниры без
/// расписания — полой точкой на каждый свой день.
Map<String, int> widgetDays(Schedule d, Filters f) {
  final out = <String, int>{};
  for (final s in d.starts) {
    if (!f.pass(s)) continue;
    final bit = switch (s.kind) {
      'women' => widgetWomen,
      'men' => widgetMen,
      'pairs' => widgetPairs,
      'dance' => widgetDance,
      _ => widgetOther,
    };
    out[s.day] = (out[s.day] ?? 0) | bit;
  }
  for (final u in d.upcoming) {
    if (!f.passUpcoming(u)) continue;
    final a = DateTime.tryParse(u.start), b = DateTime.tryParse(u.end);
    if (a == null || b == null) continue;
    // по датам, без часов: перевод часов не съедает и не удваивает день; турнир — не дольше двух месяцев
    var t = DateTime.utc(a.year, a.month, a.day);
    final end = DateTime.utc(b.year, b.month, b.day);
    for (var n = 0; !t.isAfter(end) && n < 62; n++, t = t.add(const Duration(days: 1))) {
      final k = '${t.year}-${two(t.month)}-${two(t.day)}';
      out[k] = (out[k] ?? 0) | widgetHollow;
    }
  }
  return out;
}

/// Что не так с расписанием — как в строке свежести приложения; устаревание виджет считает сам.
String widgetTrouble(Schedule d) {
  if (d.complete) return '';
  final failed = [
    for (final e in d.sources.entries)
      if (e.value != 'ok') e.key,
  ];
  return failed.length == 1 ? '${failed.first} не отвечает' : 'Источники не отвечают';
}

/// Данные виджета. Подписка действует — месяц ([data] обязателен); нет — чем закрыт виджет.
/// С месяцем уходит и срок подписки по часам телефона (until): виджет закроется сам, без приложения.
String widgetJson({required Schedule? data, required Filters filters, required Entitlement? ent, required DateTime now}) {
  final on = billingBuild && (ent?.activeAt(now) ?? false);
  final String lockTitle, lockText;
  if (!billingBuild) {
    lockTitle = 'Виджет «Месяц» недоступен';
    lockText = 'В этой версии приложения подписки нет';
  } else {
    lockTitle = 'Виджет «Месяц» входит в\u00a0подписку';
    final until = ent?.paidUntil;
    if (until == null) {
      lockText = 'Подписки нет';
    } else if (on && ent!.autoRenew) {
      // продление проходит на сервере: прошёл срок — виджет не знает, продлилось ли; знает приложение
      lockText = 'Оплачено до ${billingDay(until, now)}. Откройте приложение, чтобы проверить продление';
    } else {
      lockText = 'Подписка закончилась ${billingDay(until, now)}';
    }
  }
  return jsonEncode({
    'mode': on ? 'on' : 'locked',
    if (on) ...{
      'until': ent!.paidUntil!.subtract(ent.skew).millisecondsSinceEpoch,
      if (data != null) ...{
        'days': widgetDays(data, filters),
        'generated': data.generated.millisecondsSinceEpoch,
        'trouble': widgetTrouble(data),
        'filter': filterNames(filters, data.starts).join(', '),
      },
    },
    'lockTitle': lockTitle,
    'lockText': lockText,
    'lockOpen': billingBuild ? 'billing' : '',
    // что откроет нажатие — строкой под причиной
    'lockAction': billingBuild ? 'Открыть подписку' : '',
  });
}

/// Отдаёт виджету данные приложения, когда меняется то, что он показывает: расписание, фильтр, подписка.
class MonthWidgetSync {
  Object? _data, _filters, _ent;
  String? _last;

  /// [ent] — право из памяти устройства (billing.entitlement).
  void update(Schedule? data, Filters filters, Entitlement? ent) {
    if (!isAndroid) return;
    if (identical(data, _data) && identical(filters, _filters) && identical(ent, _ent)) return;
    _data = data;
    _filters = filters;
    _ent = ent;
    final t = DateTime.now();
    final on = billingBuild && (ent?.activeAt(t) ?? false);
    // подписка есть, а расписания ещё нет — не стирать виджету прежний месяц пустым
    if (on && data == null) return;
    final json = widgetJson(data: data, filters: filters, ent: ent, now: t);
    if (json == _last) return;
    _last = json;
    MonthWidget.publish(json);
  }
}

/// Фоновое обновление расписания (background.dart): то же, из сохранённого на устройстве — фильтр
/// и право, без сети. Приложение закрыто, а виджет узнаёт новые старты.
Future<void> widgetFromBackground(SharedPreferences p, Schedule data, DateTime t) async {
  if (!isAndroid) return;
  final f = Filters(Prefs.kinds, Prefs.tids, Prefs.athletes, levels: Prefs.levels, scope: Prefs.scope);
  final ent = Entitlement.fromCache(p.getString(BillingState.entKey));
  await MonthWidget.publish(widgetJson(data: data, filters: f, ent: ent, now: t));
}

/// Нажали на виджет: «day:2026-11-12» — вкладка «Месяц» на этом дне, «month:2026-11» — на этом
/// месяце, «billing» — страница подписки ([billing] её открывает).
void openFromWidget(BuildContext context, String what, {required VoidCallback billing}) {
  Navigator.of(context).popUntil((r) => r.isFirst);
  if (what == 'billing') {
    billing();
    return;
  }
  final m = RegExp(r'^(day|month):(\d{4}-\d{2}(?:-\d{2})?)$').firstMatch(what);
  if (m == null) return;
  monthOpen.value = m.group(2);
  homeTab.value = tabMonth;
}
