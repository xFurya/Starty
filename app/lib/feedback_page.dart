part of 'settings.dart';

// ------------------------------------------------------------------ обратная связь (feedback.dart)
//
// Страница сообщения: ошибка, идея или другое. Открывается из настроек и ссылкой «Сообщить об ошибке» в
// карточке старта и в профиле — тогда сообщение сразу знает, о чём оно, и на странице это видно.
// Что уходит вместе с текстом, написано над кнопкой. Ушли со страницы, не отправив, — текст ждёт до
// следующего открытия (пока приложение открыто).

/// К чему относится сообщение: старт или профиль. [id] уходит на сервер, остальное — для человека.
class FeedbackAbout {
  /// `start:<id старта>` или `profile:<имя>`.
  final String id;
  final IconData icon;
  final String title, subtitle;
  const FeedbackAbout({required this.id, required this.icon, required this.title, this.subtitle = ''});
}

void openFeedback(BuildContext context, {FeedbackKind kind = FeedbackKind.bug, FeedbackAbout? about, String back = 'Назад'}) {
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _FeedbackPage(kind: kind, about: about, back: back)));
}

/// «Сообщить об ошибке» под карточкой старта и профилем. В сборке без сервера ссылки нет.
class ReportLink extends StatelessWidget {
  final FeedbackAbout about;
  final EdgeInsets padding;
  const ReportLink({super.key, required this.about, this.padding = const EdgeInsets.fromLTRB(12, 14, 12, 0)});
  @override
  Widget build(BuildContext context) {
    if (!feedbackAvailable) return const SizedBox.shrink();
    final p = Palette.of(context);
    return Padding(
      padding: padding,
      child: Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () => openFeedback(context, about: about),
          style: TextButton.styleFrom(foregroundColor: p.accent, padding: const EdgeInsets.symmetric(horizontal: 10)),
          icon: const Icon(CupertinoIcons.exclamationmark_bubble, size: 18),
          label: const Text('Сообщить об ошибке', style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }
}

class _FeedbackPage extends StatefulWidget {
  final FeedbackKind kind;
  final FeedbackAbout? about;
  final String back;
  const _FeedbackPage({required this.kind, required this.about, required this.back});
  @override
  State<_FeedbackPage> createState() => _FeedbackPageState();
}

class _FeedbackPageState extends State<_FeedbackPage> {
  // черновик — до отправки или до закрытия приложения; у каждого «о чём» свой
  static final _drafts = <String, String>{};
  static String _contactDraft = '';

  late FeedbackKind _kind = widget.kind;
  late final _text = TextEditingController(text: _drafts[_key] ?? '');
  late final _contact = TextEditingController(text: _contactDraft);
  bool _busy = false, _sent = false;
  String? _error;

  String get _key => widget.about?.id ?? '';

  @override
  void initState() {
    super.initState();
    _text.addListener(() {
      _drafts[_key] = _text.text;
      setState(() {}); // кнопка оживает с первой буквой
    });
    _contact.addListener(() => _contactDraft = _contact.text);
  }

  @override
  void dispose() {
    _text.dispose();
    _contact.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await sendFeedback(kind: _kind, message: _text.text, contact: _contact.text, about: _key);
    if (!mounted) return;
    if (err == null) _drafts.remove(_key);
    setState(() {
      _busy = false;
      _error = err;
      _sent = err == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    if (_sent) {
      return _SettingsPage(
        title: 'Обратная связь',
        back: widget.back,
        slivers: [
          SliverToBoxAdapter(
            child: Plate(
              margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
              child: Column(
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: p.accent.withValues(alpha: p.isDark ? .18 : .10)),
                    child: Icon(CupertinoIcons.checkmark_alt, size: 28, color: p.accent),
                  ),
                  const SizedBox(height: 14),
                  Text('Отправлено', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: p.ink)),
                  const SizedBox(height: 6),
                  Text(
                    'Спасибо! Сообщение дошло до разработчика.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14.5, color: p.ink2, height: 1.35),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: SheetButton(neutral: true, label: 'Готово', onTap: () => Navigator.of(context).pop()),
            ),
          ),
        ],
      );
    }

    final about = widget.about;
    final hint = switch (_kind) {
      FeedbackKind.bug => 'Что случилось и где? Что вы ожидали увидеть?',
      FeedbackKind.idea => 'Что добавить или сделать удобнее?',
      FeedbackKind.other => 'Вопрос, отзыв — что угодно',
    };
    final empty = _text.text.trim().isEmpty;
    return _SettingsPage(
      title: 'Обратная связь',
      back: widget.back,
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Segmented<FeedbackKind>(
              items: const [(FeedbackKind.bug, 'Ошибка'), (FeedbackKind.idea, 'Идея'), (FeedbackKind.other, 'Другое')],
              value: _kind,
              onChanged: _busy ? null : (v) => setState(() => _kind = v),
            ),
          ),
        ),
        if (about != null) ...[
          const SliverToBoxAdapter(child: _Head('О чём')),
          SliverToBoxAdapter(
            child: Plate(
              child: _Row(icon: about.icon, title: about.title, subtitle: about.subtitle.isEmpty ? null : about.subtitle),
            ),
          ),
        ],
        const SliverToBoxAdapter(child: _Head('Сообщение')),
        SliverToBoxAdapter(
          child: Plate(
            child: TextField(
              controller: _text,
              enabled: !_busy,
              minLines: 6,
              maxLines: 14,
              maxLength: feedbackMax,
              maxLengthEnforcement: MaxLengthEnforcement.enforced,
              // счётчик — только у предела
              buildCounter: (context, {required currentLength, required isFocused, maxLength}) => currentLength < feedbackMax - 200
                  ? null
                  : Padding(
                      padding: const EdgeInsets.only(right: 4, bottom: 4),
                      child: Text('$currentLength из $feedbackMax', style: TextStyle(fontSize: 12.5, color: p.ink2, fontFeatures: tnum)),
                    ),
              keyboardType: TextInputType.multiline,
              textCapitalization: TextCapitalization.sentences,
              style: TextStyle(fontSize: 15.5, color: p.ink, height: 1.4),
              decoration: _plateField(p, hint),
            ),
          ),
        ),
        const SliverToBoxAdapter(child: _Head('Для ответа')),
        SliverToBoxAdapter(
          child: Plate(
            child: TextField(
              controller: _contact,
              enabled: !_busy,
              maxLength: feedbackContactMax,
              buildCounter: (context, {required currentLength, required isFocused, maxLength}) => null,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              enableSuggestions: false,
              style: TextStyle(fontSize: 15.5, color: p.ink),
              decoration: _plateField(p, 'Почта или Telegram'),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
            child: Text(
              'Необязательно. Без контакта ответить не получится.',
              style: TextStyle(fontSize: 13, color: p.ink2, height: 1.35),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 22, 16, 0),
            child: SheetButton(
              filled: true,
              icon: CupertinoIcons.paperplane,
              label: _busy ? 'Отправляем…' : 'Отправить',
              onTap: _busy || empty ? null : _send,
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Text(
              _error ?? 'Вместе с сообщением уйдут версия приложения и система: ${feedbackSystemLine()}.',
              style: TextStyle(fontSize: _error != null ? 14 : 13, color: _error != null ? p.live : p.ink2, height: 1.35),
            ),
          ),
        ),
      ],
    );
  }
}

/// Поле внутри плашки: без своей рамки, плашка и есть рамка.
InputDecoration _plateField(Palette p, String hint) => InputDecoration(
  hintText: hint,
  hintStyle: TextStyle(color: p.ink3),
  hintMaxLines: 3,
  filled: false,
  isDense: false,
  border: InputBorder.none,
  enabledBorder: InputBorder.none,
  focusedBorder: InputBorder.none,
  disabledBorder: InputBorder.none,
  contentPadding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
);
