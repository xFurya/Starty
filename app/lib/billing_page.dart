part of 'settings.dart';

// ------------------------------------------------------------------ подписка (billing.dart)
//
// Строка «Подписка» в разделе «Аккаунт» и её страница. Строки нет, пока подписки нет в сборке и сервер её
// не продаёт (BillingState.visible). Главное в приложении подпиской не закрывается: она добавляет итоги
// ваших, жеребьёвку и состав, «Сколько нужно» в протоколе и сводку дня и помогает приложению жить — так и
// написано на странице, без обещаний того, чего нет: где уведомление приходит позже или только при
// открытом приложении, так и сказано.

/// Строка в настройках: действует ли подписка и до какого числа.
String billingSummary(AppState st) {
  final e = st.billing.entitlement;
  final t = now();
  if (e != null && e.activeAt(t)) {
    final until = billingDay(e.paidUntil!, t);
    return e.autoRenew ? 'До $until\nПродлится автоматически' : 'До $until\nБез продления';
  }
  if (e?.paidUntil case final ended?) return 'Закончилась ${billingDay(ended, t)}';
  return 'Итоги ваших, статистика, жеребьёвка, сводка дня и поддержка приложения';
}

/// Когда приходит то, что телефон узнаёт сам, при закрытом приложении: Android проверяет раз в [every],
/// iPhone — когда система даст, компьютер — только пока приложение открыто.
String _closed(String every) => isAndroid
    ? 'При закрытом приложении — с задержкой до $every, в экономии энергии дольше'
    : isIos
    ? 'При закрытом приложении — когда iPhone даст ему обновиться'
    : 'Пока приложение открыто';

/// Итоги ваших: поправить показанное уведомление можно только на Android — там место обновляется,
/// пока выступают остальные; на остальных итог приходит, когда выступили все.
String get _resultsText => isAndroid
    ? 'Место и баллы ваших после проката; пока выступают остальные, место обновляется'
    : 'Место и баллы ваших, когда выступят все';

/// Виджет «Месяц»: ставится только на рабочий стол Android.
String get _widgetText => isAndroid
    ? 'Месяц со стартами на рабочем столе, как во вкладке «Месяц»'
    : 'Только на Android: месяц со стартами на рабочем столе, как во вкладке «Месяц»';

/// Как поставить виджет самому, если рабочий стол не умеет по просьбе приложения.
const _widgetHand = 'Удержите палец на пустом месте рабочего стола, откройте «Виджеты» и найдите «Фигурное катание»';

const _lineupText = 'Время выхода ваших после жеребьёвки, кто вошёл в состав и кто снялся';
const _needsText = 'В протоколе: сколько баллов вашим нужно во втором сегменте на первое место и на пьедестал';
const _statsText = 'В профиле спортсмена: баллы от старта к старту, какие прыжки исполняются чисто, уровни вращений и дорожек — по протоколам с 2018 года';

void openBilling(BuildContext context, AppState state) {
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _BillingPage(state: state)));
}

/// Что после возврата из оплаты.
enum _Pay { waiting, late, failed, unfinished }

class _BillingPage extends StatefulWidget {
  final AppState state;
  const _BillingPage({required this.state});
  @override
  State<_BillingPage> createState() => _BillingPageState();
}

class _BillingPageState extends State<_BillingPage> {
  String? _planId;
  bool _renew = false;
  bool _busy = false;
  String? _error;
  _Pay? _pay;

  /// Итог отказа с возвратом — остаётся на странице, пока её не закрыли.
  String? _refunded;

  /// Виджет «Месяц» (Android): сколько стоит на рабочем столе, умеет ли рабочий стол поставить его сам.
  ({int placed, bool canPin})? _widget;

  /// Рабочий стол не поставил виджет по просьбе — дальше только руками.
  bool _pinFailed = false;

  /// Вернулись из окна рабочего стола «Добавить виджет» — посмотреть, поставлен ли.
  AppLifecycleListener? _life;

  AppState get st => widget.state;

  @override
  void initState() {
    super.initState();
    st.refreshBilling(history: true);
    if (isAndroid) {
      _widgetStatus();
      _life = AppLifecycleListener(onResume: _widgetStatus);
    }
  }

  @override
  void dispose() {
    _life?.dispose();
    super.dispose();
  }

  Future<void> _widgetStatus() async {
    final s = await MonthWidget.status();
    if (mounted) setState(() => _widget = s);
  }

  /// Попросить рабочий стол поставить виджет; человек подтверждает в его окне.
  Future<void> _pin() async {
    final ok = await MonthWidget.pin();
    if (!mounted) return;
    if (!ok) setState(() => _pinFailed = true);
    // рабочий стол может поставить виджет чуть позже возврата в приложение
    Future.delayed(const Duration(seconds: 2), () => mounted ? _widgetStatus() : null);
  }

  BillingPlan? _plan(BillingOffer o) => o.plans.where((x) => x.id == _planId).firstOrNull ?? o.plans.first;

  /// Текст согласия на продление — ровно он и уходит на сервер в журнал согласий.
  static String _consent(BillingPlan plan, BillingOffer o) =>
      '${plan.price} ${periodWords(plan.periodDays)} с той же карты. '
      'За ${o.noticeDays} ${plural(o.noticeDays, 'день', 'дня', 'дней')} до списания придёт письмо. '
      'Отключить можно в любой момент здесь же.';

  Future<void> _start(BillingPlan plan, BillingOffer o) async {
    setState(() {
      _busy = true;
      _error = null;
      _pay = null;
    });
    try {
      final c = await st.startPayment(plan, renew: _renew, consent: _renew ? 'Продлевать автоматически. ${_consent(plan, o)}' : null);
      if (!mounted) return;
      final back = await openPayment(context, c.url, c.returnUrl);
      if (!mounted) return;
      setState(() => _pay = _Pay.waiting);
      // закрыл страницу сам — спрашиваем один раз; вернул сервис (или оплата в браузере системы) — ждём
      final ok = await st.awaitPayment(c.paymentId, limit: back == false ? Duration.zero : const Duration(seconds: 40));
      if (!mounted) return;
      setState(() => _pay = switch (ok) {
        true => null,
        false => _Pay.failed,
        null => back == false ? _Pay.unfinished : _Pay.late,
      });
    } on SyncError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _check() async {
    setState(() => _busy = true);
    await st.refreshBilling(history: true);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (st.billing.activeAt(now())) _pay = null;
    });
  }

  Future<void> _cancelRenew(Entitlement e) async {
    final go = await _confirm(
      context,
      title: 'Отключить продление?',
      text: 'Подписка будет действовать до ${billingDay(e.paidUntil!, now())}, дальше не продлится. Карта забудется.',
      action: 'Отключить',
    );
    if (!go || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await st.cancelRenew();
    if (mounted) {
      setState(() {
        _busy = false;
        _error = err;
      });
    }
  }

  Future<void> _refund(Entitlement e) async {
    final cur = e.currency ?? 'RUB';
    final go = await _confirm(
      context,
      title: 'Отказаться от подписки?',
      text: 'Вернём ${money(e.refundMinor, cur)} за неиспользованные дни. Подписка закончится сразу.',
      action: 'Отказаться',
    );
    if (!go || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final (r, err) = await st.refundSubscription();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
      if (r != null) _refunded = _refundText(r);
    });
  }

  /// Как вернутся деньги — по факту: сервис вернул сразу, или продавец вернёт вручную.
  static String _refundText(BillingRefund r) => [
    if (r.refunded > 0) 'Возврат ${money(r.refunded, r.currency)} отправлен в банк: обычно деньги приходят на карту за несколько дней.',
    if (r.manual > 0) 'Заявка на возврат ${money(r.manual, r.currency)} принята: продавец вернёт деньги на карту в течение 10 дней.',
    if (r.refunded == 0 && r.manual == 0) 'Подписка закончилась. Возвращать было нечего.',
  ].join('\n');

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: st,
      builder: (context, _) {
        final p = Palette.of(context);
        final b = st.billing;
        final t = now();
        final e = b.entitlement;
        final active = e != null && e.activeAt(t);
        final offer = b.offer;
        final signedIn = st.account != null;
        return _SettingsPage(
          title: 'Подписка',
          slivers: [
            SliverToBoxAdapter(child: _card(p, e, active, signedIn, offer, t)),
            if (b.problem != null && (e != null || offer != null)) SliverToBoxAdapter(child: _stale(p, b.problem!, e)),
            if (b.preview) SliverToBoxAdapter(child: _preview(p)),
            for (final w in [
              if (b.preview && !active) ..._digest(p),
              if (!active && offer != null && !b.preview) ..._perks(p),
              if (!signedIn && !(b.preview && offer == null)) ..._signIn(p)
              else if (active) ..._active(p, e)
              else if (offer != null && signedIn) ..._buy(p, offer),
              if (signedIn && (b.payments?.isNotEmpty ?? false)) ..._history(p, b.payments!, t),
            ])
              SliverToBoxAdapter(child: w),
          ],
        );
      },
    );
  }

  /// Шапка: что с подпиской сейчас.
  Widget _card(Palette p, Entitlement? e, bool active, bool signedIn, BillingOffer? offer, DateTime t) {
    if (active) {
      return _ProfileCard(
        letter: null,
        icon: CupertinoIcons.sparkles,
        title: 'Подписка до ${billingDay(e!.paidUntil!, t)}',
        titleLines: 2,
        status: e.autoRenew ? 'Продлится автоматически' : 'Без продления',
      );
    }
    if (st.billing.preview) {
      return const _ProfileCard(letter: null, icon: CupertinoIcons.sparkles, title: 'Подписка', status: 'Режим владельца: всё включено');
    }
    final String status;
    if (!signedIn) {
      status = st.syncCodeOn ? 'Нужна почта в аккаунте' : 'Нужен вход по почте';
    } else if (e?.paidUntil case final ended?) {
      status = 'Закончилась ${billingDay(ended, t)}';
    } else if (offer != null) {
      status = 'Не оформлена';
    } else {
      status = st.billing.offerChecked ? 'Сейчас не продаётся' : 'Загрузка…';
    }
    return _ProfileCard(letter: null, icon: CupertinoIcons.sparkles, title: 'Подписка', status: status);
  }

  /// Сервер не ответил: показанное — из памяти устройства, и об этом сказано.
  Widget _stale(Palette p, String problem, Entitlement? e) {
    final at = e?.checkedAt;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              at == null ? problem : '$problem. Показано, что было известно ${dateTime(at)}',
              style: TextStyle(fontSize: 13.5, color: p.live, height: 1.3),
            ),
          ),
          _TextAction('Повторить', onTap: _busy ? () {} : _check),
        ],
      ),
    );
  }

  /// Режим владельца: все функции включены на этом устройстве без оплаты — оценить до продажи.
  Widget _preview(Palette p) => Padding(
    padding: const EdgeInsets.only(top: 14),
    child: Plate(
      child: _Row(
        icon: CupertinoIcons.eye,
        title: 'Режим владельца',
        subtitle: 'Все функции подписки включены на этом устройстве без оплаты. Остальным они недоступны',
        action: 'Выключить',
        onAction: () => st.setPreview(false),
      ),
    ),
  );

  List<Widget> _perks(Palette p) => [
    const _Head('Что даёт'),
    Plate(
      child: Column(
        children: [
          _Row(icon: CupertinoIcons.rosette, title: 'Итоги ваших', subtitle: '$_resultsText\n${_closed('15 минут')}'),
          const Hairline(),
          _Row(icon: CupertinoIcons.list_number, title: 'Жеребьёвка и состав', subtitle: '$_lineupText\n${_closed('3 часов')}'),
          const Hairline(),
          const _Row(icon: CupertinoIcons.scope, title: 'Сколько нужно', subtitle: _needsText),
          const Hairline(),
          const _Row(icon: CupertinoIcons.chart_bar, title: 'Статистика', subtitle: _statsText),
          const Hairline(),
          const _Row(
            icon: CupertinoIcons.sun_max,
            title: 'Сводка дня',
            subtitle: 'Одно уведомление утром: кто из ваших выступает сегодня и во сколько',
          ),
          const Hairline(),
          _Row(icon: CupertinoIcons.calendar, title: 'Виджет «Месяц»', subtitle: _widgetText),
          const Hairline(),
          const _Row(
            icon: CupertinoIcons.heart,
            title: 'Поддержка приложения',
            subtitle: 'Расписание, протоколы, трансляции и уведомления о стартах остаются бесплатными для всех',
          ),
        ],
      ),
    ),
  ];

  List<Widget> _signIn(Palette p) => [
    const SizedBox(height: 22),
    Plate(
      child: _Row(
        icon: CupertinoIcons.mail,
        title: st.syncCodeOn ? 'Привязать почту' : 'Войти по почте',
        subtitle: 'Подписка оформляется на аккаунт: действует на всех ваших устройствах, чеки приходят на почту',
        onTap: () => openAccount(context, st),
        trailing: const _Chevron(),
      ),
    ),
  ];

  List<Widget> _buy(Palette p, BillingOffer o) {
    final plan = _plan(o)!;
    final consent = _consent(plan, o);
    return [
      const _Head('Срок'),
      Plate(
        child: Column(
          children: [
            for (final (i, x) in o.plans.indexed) ...[
              if (i > 0) const Hairline(),
              _Row(
                icon: CupertinoIcons.calendar,
                title: x.title,
                onTap: _busy ? null : () => setState(() => _planId = x.id),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _Value(x.price),
                    Padding(
                      padding: const EdgeInsets.only(left: 6, right: 4),
                      child: Icon(
                        x.id == plan.id ? CupertinoIcons.checkmark_circle_fill : CupertinoIcons.circle,
                        size: 22,
                        color: x.id == plan.id ? p.accent : p.ink3,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      const SizedBox(height: 14),
      // согласие на продление — отдельно и выключено, пока человек сам не включит
      Plate(
        child: _SwitchRow(
          icon: CupertinoIcons.arrow_2_circlepath,
          title: 'Продлевать автоматически',
          subtitle: consent,
          value: _renew,
          onChanged: (v) {
            if (!_busy) setState(() => _renew = v);
          },
        ),
      ),
      const SizedBox(height: 18),
      if (_pay != null)
        _payState(p)
      else
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SheetButton(
            filled: true,
            label: _busy ? 'Открываем оплату…' : 'Оплатить ${plan.price}',
            onTap: _busy ? null : () => _start(plan, o),
          ),
        ),
      if (_error != null) _errorText(p),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
        child: Text(
          [
            'Нажимая «Оплатить», вы принимаете условия подписки. '
                'Отказаться можно в любой момент: за неиспользованные дни деньги вернутся.',
            if (o.seller != null) 'Продавец: ${o.seller}',
          ].join('\n'),
          style: TextStyle(fontSize: 13, color: p.ink2, height: 1.35),
        ),
      ),
      const SizedBox(height: 14),
      Plate(
        child: _Row(
          icon: CupertinoIcons.doc_text,
          title: 'Условия подписки',
          onTap: () => openLink(context, o.url, 'Условия подписки'),
          trailing: const _Chevron(),
        ),
      ),
    ];
  }

  /// После возврата из оплаты: ждём банк, не дождались, не прошла, не завершена.
  Widget _payState(Palette p) {
    final (icon, title, sub, color) = switch (_pay!) {
      _Pay.waiting => (null, 'Ждём подтверждения банка', 'Обычно это несколько секунд', null),
      _Pay.late => (
        CupertinoIcons.clock,
        'Банк ещё не подтвердил оплату',
        'Как только подтвердит, подписка появится здесь сама',
        null,
      ),
      _Pay.unfinished => (
        CupertinoIcons.xmark_circle,
        'Оплата не завершена',
        'Если вы всё же оплатили, подписка появится здесь, как только банк подтвердит',
        null,
      ),
      _Pay.failed => (CupertinoIcons.exclamationmark_circle, 'Оплата не прошла', 'Можно попробовать ещё раз', p.live),
    };
    return Plate(
      child: _Row(
        icon: icon ?? CupertinoIcons.hourglass,
        iconColor: color,
        title: title,
        subtitle: sub,
        trailing: icon == null
            ? const Padding(
                padding: EdgeInsets.only(right: 8),
                child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              )
            : null,
        action: icon == null ? null : (_pay == _Pay.late ? 'Проверить' : 'Ещё раз'),
        onAction: _busy ? () {} : (_pay == _Pay.late ? _check : () => setState(() => _pay = null)),
      ),
    );
  }

  Widget _errorText(Palette p) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
    child: Text(_error!, style: TextStyle(fontSize: 14, color: p.live)),
  );

  List<Widget> _active(Palette p, Entitlement e) {
    final cur = e.currency ?? 'RUB';
    final until = billingDay(e.paidUntil!, now());
    return [
      ..._digest(p),
      const _Head('Продление'),
      Plate(
        child: Column(
          children: [
            if (e.autoRenew)
              _Row(
                icon: CupertinoIcons.arrow_2_circlepath,
                title: 'Продление включено',
                subtitle: [
                  if (e.renewMinor != null) '$until спишется ${money(e.renewMinor!, cur)}',
                  if (e.methodTitle != null) e.methodTitle!,
                ].join('\n'),
                action: 'Отключить',
                onAction: _busy ? () {} : () => _cancelRenew(e),
              )
            else
              _Row(
                icon: CupertinoIcons.arrow_2_circlepath,
                iconColor: p.ink2,
                title: 'Продление выключено',
                subtitle: 'Подписка закончится $until, деньги больше не спишутся',
              ),
            if (e.refundMinor > 0) ...[
              const Hairline(),
              _Row(
                icon: CupertinoIcons.arrow_uturn_left,
                iconColor: p.live,
                title: 'Отказаться с возвратом',
                subtitle: 'Вернём ${money(e.refundMinor, cur)} за неиспользованные дни\nПодписка закончится сразу',
                onTap: _busy ? null : () => _refund(e),
                trailing: const _Chevron(),
              ),
            ],
          ],
        ),
      ),
      if (_error != null) _errorText(p),
      if (_refunded != null) _note(p, _refunded!),
    ];
  }

  Widget _note(Palette p, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
    child: Text(text, style: TextStyle(fontSize: 14, color: p.ink, height: 1.35)),
  );

  /// Сводка дня: включена ли, во сколько и — честно — придёт ли она вообще.
  List<Widget> _digest(Palette p) {
    final m = st.billing.digestSetting;
    final on = m >= 0;
    final f = st.follow;
    final why = [
      if (on && !st.rules.on) 'Уведомления выключены — сводка не придёт',
      if (on && st.rules.on && st.allowed == false) 'Уведомления запрещены в настройках телефона — сводка не придёт',
      if (on && f.names.isEmpty && !f.russians && !f.belarusians) 'Вы никого не отслеживаете — сводке не о ком рассказать',
    ];
    return [
      const _Head('Что входит'),
      Plate(
        child: Column(
          children: [
            _resultsRow(p),
            const Hairline(),
            _lineupRow(p),
            const Hairline(),
            _Row(
              icon: CupertinoIcons.sun_max,
              title: 'Сводка дня',
              subtitle: [
                ...why,
                on ? 'Каждый день в ${digestLabel(m)}: кто из ваших выступает сегодня' : 'Выключена',
              ].join('\n'),
              subtitleColor: why.isEmpty ? null : p.live,
              onTap: () => st.setDigest(on ? BillingState.digestOff : BillingState.digestDefault),
              trailing: Switch(
                value: on,
                onChanged: (v) => st.setDigest(v ? BillingState.digestDefault : BillingState.digestOff),
              ),
            ),
            if (on) ...[
              const Hairline(),
              _ChoiceRow<int>(
                icon: CupertinoIcons.clock,
                title: 'Время',
                value: m,
                items: [for (final x in {...digestTimes, m}.toList()..sort()) (x, digestLabel(x))],
                caption: (_) => 'По московскому времени',
                showValue: true,
                onChanged: st.setDigest,
              ),
            ],
            const Hairline(),
            const _Row(icon: CupertinoIcons.scope, title: 'Сколько нужно', subtitle: _needsText),
            const Hairline(),
            const _Row(icon: CupertinoIcons.chart_bar, title: 'Статистика', subtitle: _statsText),
            const Hairline(),
            _widgetRow(),
          ],
        ),
      ),
    ];
  }

  /// Виджет «Месяц»: уже стоит, поставить отсюда или — если рабочий стол не умеет — как поставить самому.
  Widget _widgetRow() {
    const icon = CupertinoIcons.calendar, title = 'Виджет «Месяц»';
    final w = _widget;
    if (!isAndroid) return _Row(icon: icon, title: title, subtitle: _widgetText);
    if (w != null && w.placed > 0) {
      return _Row(icon: icon, title: title, subtitle: w.placed == 1 ? 'На рабочем столе' : 'На рабочем столе: ${w.placed}');
    }
    if (w != null && w.canPin && !_pinFailed) {
      return _Row(icon: icon, title: title, subtitle: _widgetText, action: 'Добавить', onAction: _pin);
    }
    return _Row(icon: icon, title: title, subtitle: '$_widgetText\n$_widgetHand');
  }

  /// Итоги ваших: включены ли и — честно — придут ли. Отслеживаемые — и по имени, и «все россияне».
  Widget _resultsRow(Palette p) {
    final on = st.billing.resultsSetting;
    final f = st.follow;
    final why = [
      if (on && !st.rules.on) 'Уведомления выключены — не придут',
      if (on && st.rules.on && st.allowed == false) 'Уведомления запрещены в настройках телефона — не придут',
      if (on && f.names.isEmpty && !f.russians && !f.belarusians) 'Вы никого не отслеживаете — не о ком сообщать',
    ];
    return _Row(
      icon: CupertinoIcons.rosette,
      title: 'Итоги ваших',
      subtitle: [
        ...why,
        if (on) ...['$_resultsText — по стартам, о которых приходят уведомления', _closed('15 минут')] else 'Выключено',
      ].join('\n'),
      subtitleColor: why.isEmpty ? null : p.live,
      onTap: () => st.setResults(!on),
      trailing: Switch(value: on, onChanged: st.setResults),
    );
  }

  /// Жеребьёвка и состав: включены ли и — честно — придут ли. Нужны отслеживаемые по имени:
  /// «все россияне» сюда не входят.
  Widget _lineupRow(Palette p) {
    final on = st.billing.lineupSetting;
    final why = [
      if (on && !st.rules.on) 'Уведомления выключены — не придут',
      if (on && st.rules.on && st.allowed == false) 'Уведомления запрещены в настройках телефона — не придут',
      if (on && st.follow.names.isEmpty) 'Вы никого не отслеживаете по имени — не о ком сообщать',
    ];
    return _Row(
      icon: CupertinoIcons.list_number,
      title: 'Жеребьёвка и состав',
      subtitle: [
        ...why,
        if (on) ...[_lineupText, _closed('3 часов')] else 'Выключено',
      ].join('\n'),
      subtitleColor: why.isEmpty ? null : p.live,
      onTap: () => st.setLineup(!on),
      trailing: Switch(value: on, onChanged: st.setLineup),
    );
  }

  List<Widget> _history(Palette p, List<BillingPayment> pays, DateTime t) => [
    const _Head('Платежи'),
    Plate(
      child: Column(
        children: [
          for (final (i, x) in pays.indexed) ...[
            if (i > 0) const Hairline(),
            _Row(
              icon: CupertinoIcons.creditcard,
              iconColor: x.status == 'succeeded' || x.status == 'refunded' ? null : p.ink2,
              title: x.title,
              subtitle: [billingDay(x.at, t), ...x.state].join('\n'),
              // не прошла — денег не взяли: сумма зачёркнута, а не стоит наравне со списанными
              trailing: x.status == 'canceled'
                  ? Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Text(
                        money(x.amountMinor, x.currency),
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: p.ink3,
                          decoration: TextDecoration.lineThrough,
                          decorationColor: p.ink3,
                          fontFeatures: tnum,
                        ),
                      ),
                    )
                  : _Value(money(x.amountMinor, x.currency)),
            ),
          ],
        ],
      ),
    ),
  ];
}

/// Вопрос перед действием с деньгами: заголовок, что именно произойдёт, «Отмена» и [action].
Future<bool> _confirm(BuildContext context, {required String title, required String text, required String action}) async {
  final go = await showCupertinoDialog<bool>(
    context: context,
    builder: (c) => CupertinoAlertDialog(
      title: Text(title),
      content: Padding(padding: const EdgeInsets.only(top: 6), child: Text(text)),
      actions: [
        CupertinoDialogAction(onPressed: () => Navigator.pop(c, false), child: const Text('Отмена')),
        CupertinoDialogAction(isDestructiveAction: true, onPressed: () => Navigator.pop(c, true), child: Text(action)),
      ],
    ),
  );
  return go == true;
}
