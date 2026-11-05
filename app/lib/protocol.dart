// Маршрут протокола: у старта есть файл протокола — наш экран (на всех платформах, включая Windows).
// Файла нет — сразу оригинал: встроенный браузер на мобильных, браузер системы на Windows и в вебе.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'data.dart';
import 'protocol_screen.dart';
import 'state.dart' show AppState;

Future<void> openProtocol(BuildContext context, Start s, {AppState? state}) async {
  if (s.proto != null) {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProtocolScreen(start: s, state: state)));
    return;
  }
  await openOriginal(context, s.src, s.title);
}

/// Оригинал протокола на сайте: во встроенном браузере приложения; на Windows и в вебе встроенного
/// у Flutter нет — браузер системы. [replace] — экран протокола заменяется оригиналом (файла нет).
Future<void> openOriginal(BuildContext context, String url, String title, {bool replace = false}) async {
  if (url.isEmpty) return;
  if (kIsWeb || defaultTargetPlatform == TargetPlatform.windows) {
    await launchUrl(Uri.parse(url), webOnlyWindowName: '_blank', mode: LaunchMode.externalApplication);
    if (replace && context.mounted) Navigator.of(context).maybePop();
    return;
  }
  final route = MaterialPageRoute<void>(builder: (_) => ProtocolPage(url: url, title: title));
  final nav = Navigator.of(context);
  await (replace ? nav.pushReplacement(route) : nav.push(route));
}
/// Ссылка изнутри приложения. Правило владельца: из приложения не выходим. [preferApp] — сначала
/// приложение, которое умеет эту ссылку (Okko, VK Видео, YouTube), если оно установлено; браузер
/// системы при этом не открывается. Нет такого приложения — встроенный браузер.
Future<void> openLink(BuildContext context, String url, String title, {bool preferApp = false}) async {
  if (url.isEmpty) return;
  if (preferApp && !kIsWeb && defaultTargetPlatform != TargetPlatform.windows) {
    try {
      if (await launchUrl(Uri.parse(url), mode: LaunchMode.externalNonBrowserApplication)) return;
    } catch (_) {}
  }
  if (context.mounted) await openOriginal(context, url, title);
}

class ProtocolPage extends StatefulWidget {
  final String url, title;
  const ProtocolPage({super.key, required this.url, required this.title});
  @override
  State<ProtocolPage> createState() => _ProtocolPageState();
}

class _ProtocolPageState extends State<ProtocolPage> {
  late final WebViewController _c;
  int _progress = 0;
  bool _failed = false;

  /// PDF встроенный браузер Android не показывает — открываем через просмотрщик. Просмотрщик
  /// хранит файл у себя по адресу: метка времени в адресе заставляет его взять файл заново.
  static String _viewable(String url) {
    if (!url.toLowerCase().endsWith('.pdf')) return url;
    final fresh = '$url${url.contains('?') ? '&' : '?'}t=${DateTime.now().millisecondsSinceEpoch}';
    return 'https://docs.google.com/viewer?embedded=true&url=${Uri.encodeComponent(fresh)}';
  }

  /// Страница всегда с сайта, а не из памяти браузера: протокол на табло меняется каждую минуту.
  static const _noCache = {'Cache-Control': 'no-cache', 'Pragma': 'no-cache'};

  Future<void> _load(String url) async {
    await _c.clearCache();
    await _c.loadRequest(Uri.parse(url), headers: _noCache);
  }

  Future<void> _reload() async {
    setState(() => _failed = false);
    final now = Uri.tryParse(await _c.currentUrl() ?? '');
    if (now == null || !now.hasScheme || now.scheme == 'about') return _load(_viewable(widget.url));
    // файл в просмотрщике — заново и с новой меткой времени, иначе просмотрщик отдаст свою копию
    final pdf = now.host == 'docs.google.com' ? now.queryParameters['url'] : null;
    if (pdf != null) return _load(_viewable(pdf.replaceFirst(RegExp(r'[?&]t=\d+$'), '')));
    await _c.clearCache();
    await _c.reload();
  }

  @override
  void initState() {
    super.initState();
    _c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..enableZoom(true)
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (p) => mounted ? setState(() => _progress = p) : null,
        // как только страница загружена — память браузера чистая: следующая ссылка и «назад» идут на сайт
        onPageFinished: (_) => _c.clearCache(),
        onWebResourceError: (e) {
          if (e.isForMainFrame ?? true) setState(() => _failed = true);
        },
        onNavigationRequest: (r) {
          // ссылка страницы на приложение (intent:, okko:, vk:) — открываем его, если установлено
          final scheme = Uri.tryParse(r.url)?.scheme ?? '';
          if (scheme != 'http' && scheme != 'https' && scheme != 'about' && scheme != 'data' && scheme != 'blob') {
            launchUrl(Uri.parse(r.url), mode: LaunchMode.externalNonBrowserApplication).catchError((_) => false);
            return NavigationDecision.prevent;
          }
          // ссылки на PDF внутри протокола — тоже через просмотрщик
          if (r.url.toLowerCase().endsWith('.pdf') && !r.url.contains('docs.google.com')) {
            _load(_viewable(r.url));
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
      ));
    _load(_viewable(widget.url));
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _c.canGoBack()) {
          await _c.goBack();
        } else if (context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17)),
          actions: [
            IconButton(
              tooltip: 'Обновить',
              icon: const Icon(Icons.refresh),
              onPressed: _reload,
            ),
          ],
          bottom: _progress < 100
              ? PreferredSize(preferredSize: const Size.fromHeight(2), child: LinearProgressIndicator(value: _progress / 100, minHeight: 2))
              : null,
        ),
        body: _failed
            ? Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text('Протокол недоступен'),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: _reload,
                    child: const Text('Повторить'),
                  ),
                ]),
              )
            : WebViewWidget(controller: _c),
      ),
    );
  }
}
