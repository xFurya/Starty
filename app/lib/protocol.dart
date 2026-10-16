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

  /// PDF встроенный браузер Android не показывает — открываем через просмотрщик.
  static String _viewable(String url) => url.toLowerCase().endsWith('.pdf')
      ? 'https://docs.google.com/viewer?embedded=true&url=${Uri.encodeComponent(url)}'
      : url;

  @override
  void initState() {
    super.initState();
    _c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..enableZoom(true)
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (p) => mounted ? setState(() => _progress = p) : null,
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
            _c.loadRequest(Uri.parse(_viewable(r.url)));
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
      ))
      ..loadRequest(Uri.parse(_viewable(widget.url)));
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
              onPressed: () {
                setState(() => _failed = false);
                _c.reload();
              },
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
                    onPressed: () {
                      setState(() => _failed = false);
                      _c.reload();
                    },
                    child: const Text('Повторить'),
                  ),
                ]),
              )
            : WebViewWidget(controller: _c),
      ),
    );
  }
}
