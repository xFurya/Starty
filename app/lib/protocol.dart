// Протокол турнира внутри приложения: встроенный браузер, PDF — через просмотрщик.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

Future<void> openProtocol(BuildContext context, String url, String title) async {
  if (url.isEmpty) return;
  if (kIsWeb) {
    await launchUrl(Uri.parse(url), webOnlyWindowName: '_blank');
    return;
  }
  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProtocolPage(url: url, title: title)));
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
            IconButton(
              tooltip: 'В браузере',
              icon: const Icon(Icons.open_in_browser),
              onPressed: () => launchUrl(Uri.parse(widget.url), mode: LaunchMode.externalApplication),
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
