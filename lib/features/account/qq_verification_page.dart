import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:material_ui/material_ui.dart';

import '../../online/qq/auth/qq_credential.dart';
import '../../online/qq/auth/qq_login_protocol.dart';
import '../../online/qq/auth/qq_verification_protocol.dart';

Future<QqVerificationResult?> showQqVerification(
  BuildContext context,
  QqSecurityChallenge challenge,
) => Navigator.of(context).push<QqVerificationResult>(
  MaterialPageRoute(builder: (_) => QqVerificationPage(challenge: challenge)),
);

class QqVerificationPage extends StatefulWidget {
  const QqVerificationPage({super.key, required this.challenge});
  final QqSecurityChallenge challenge;
  @override
  State<QqVerificationPage> createState() => _QqVerificationPageState();
}

class _QqVerificationPageState extends State<QqVerificationPage> {
  WebViewEnvironment? _environment;
  InAppWebViewController? _web;
  CookieManager? _cookies;
  Directory? _profile;
  Uri? _lastUri;
  String _lastCookie = '';
  String? _userAgent;
  Size _viewport = const Size(420, 640);
  bool _ready = false;
  bool _finishing = false;
  bool _challengeSeen = false;
  bool _resizing = false;
  String? _error;

  bool get _windows => defaultTargetPlatform == TargetPlatform.windows;

  @override
  void initState() {
    super.initState();
    _lastUri = widget.challenge.uri;
    _lastCookie = widget.challenge.cookie;
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    try {
      if (!isQqVerificationUri(widget.challenge.uri)) {
        throw const FormatException();
      }
      if (_windows) {
        _profile ??= await Directory.systemTemp.createTemp(
          'motif-qq-verification-',
        );
        _environment ??= await WebViewEnvironment.create(
          settings: WebViewEnvironmentSettings(userDataFolder: _profile!.path),
        );
        var agent = '';
        try {
          agent = await InAppWebViewController.getDefaultUserAgent();
        } catch (_) {}
        _userAgent = qqVerificationMobileUserAgent(agent);
      }
      _cookies = CookieManager.instance(webViewEnvironment: _environment);
      if (mounted) setState(() => _ready = true);
    } catch (_) {
      if (mounted) {
        setState(() => _error = '验证窗口暂时无法启动，请检查网络与系统 WebView 组件后重试。');
      }
    }
  }

  void _remember(WebUri? value) {
    final uri = value == null ? null : Uri.tryParse(value.toString());
    if (uri != null && isQqVerificationUri(uri)) _lastUri = uri;
  }

  Future<void> _syncViewport() async {
    if (!_windows || _web == null || _resizing) return;
    _resizing = true;
    try {
      Size applied;
      do {
        applied = _viewport;
        try {
          await _web!
              .callDevToolsProtocolMethod(
                methodName: 'Emulation.setDeviceMetricsOverride',
                parameters: qqVerificationDeviceMetrics(
                  applied.width.round(),
                  applied.height.round(),
                ),
              )
              .timeout(const Duration(seconds: 2));
        } catch (_) {}
      } while (mounted && applied != _viewport);
    } finally {
      _resizing = false;
    }
  }

  void _resize(Size size) {
    if (size == _viewport) return;
    _viewport = size;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_syncViewport());
    });
  }

  Future<void> _load(InAppWebViewController controller) async {
    _web = controller;
    controller.addJavaScriptHandler(
      handlerName: 'motifQqProof',
      callback: (args) async {
        try {
          _remember(
            await controller.getUrl().timeout(const Duration(seconds: 2)),
          );
        } catch (_) {}
        if (!mounted || _lastUri == null || !isQqVerificationUri(_lastUri!)) {
          return;
        }
        if (args.isEmpty || args.first is! Map) return;
        final data = args.first as Map;
        if (data['kind'] == 'shown') {
          _challengeSeen = true;
        } else if (data['kind'] == 'cancel') {
          _complete(null);
        } else if (data['kind'] == 'complete' ||
            data['kind'] == 'closed' && _challengeSeen) {
          await _finish();
        }
      },
    );
    try {
      if (_windows) {
        await controller.callDevToolsProtocolMethod(
          methodName: 'Network.enable',
          parameters: {},
        );
        try {
          await controller.callDevToolsProtocolMethod(
            methodName: 'Network.clearBrowserCookies',
            parameters: {},
          );
        } catch (_) {}
        await _syncViewport();
      } else {
        await _cookies!.deleteAllCookies();
      }
      final targets = {widget.challenge.uri.toString()};
      if (widget.challenge.uri.host == 'qq.com' ||
          widget.challenge.uri.host.endsWith('.qq.com')) {
        targets.addAll(['https://y.qq.com/', 'https://c.y.qq.com/']);
      }
      for (final target in targets) {
        for (final entry in qqCookieValues(widget.challenge.cookie).entries) {
          if (_windows) {
            final result = await controller.callDevToolsProtocolMethod(
              methodName: 'Network.setCookie',
              parameters: {
                'url': target,
                'name': entry.key,
                'value': entry.value,
                'path': '/',
                'secure': true,
              },
            );
            if (result is Map && result['success'] == false) {
              throw const FormatException();
            }
          } else {
            await _cookies!.setCookie(
              url: WebUri(target),
              name: entry.key,
              value: entry.value,
              path: '/',
              isSecure: true,
            );
          }
        }
      }
      if (!mounted) return;
      await controller.loadUrl(
        urlRequest: URLRequest(url: WebUri(widget.challenge.uri.toString())),
      );
    } catch (_) {
      if (mounted) setState(() => _error = '验证网页加载失败，请重试。');
    }
  }

  Future<String> _snapshot() async {
    final web = _web;
    if (web == null || _cookies == null) return _lastCookie;
    try {
      _remember(await web.getUrl().timeout(const Duration(seconds: 2)));
    } catch (_) {}
    final targets = {
      widget.challenge.uri.toString(),
      'https://y.qq.com/',
      'https://c.y.qq.com/',
      if (_lastUri != null) _lastUri.toString(),
    }.toList();
    if (_windows) {
      return collectQqWindowsVerificationCookies(
        fallback: _lastCookie,
        urls: targets,
        call: (method, parameters) => web.callDevToolsProtocolMethod(
          methodName: method,
          parameters: parameters,
        ),
      );
    }
    return collectQqAndroidVerificationCookies(
      fallback: _lastCookie,
      urls: targets,
      read: (url) async {
        final values = await _cookies!.getCookies(
          url: WebUri(url),
          webViewController: web,
        );
        return {for (final value in values) value.name: value.value};
      },
    );
  }

  Future<void> _finish() async {
    if (_finishing || !mounted) return;
    setState(() {
      _finishing = true;
      _error = null;
    });
    final cookie = await _snapshot();
    if (!mounted) return;
    _lastCookie = cookie;
    _complete(QqVerificationResult(cookie: cookie));
  }

  void _complete(QqVerificationResult? result) {
    if (!mounted) return;
    final navigator = Navigator.of(context);
    final route = ModalRoute.of(context);
    if (route == null || route.isCurrent) {
      navigator.pop(result);
    } else {
      navigator.removeRoute(route, result);
    }
  }

  void _retry() {
    if (_finishing) return;
    setState(() => _error = null);
    final web = _web;
    if (web == null) {
      unawaited(_prepare());
    } else {
      unawaited(_load(web));
    }
  }

  Widget _browser() => InAppWebView(
    key: const Key('qq-verification-webview'),
    webViewEnvironment: _environment,
    initialUserScripts: UnmodifiableListView([
      UserScript(
        source: qqVerificationProofScript,
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        forMainFrameOnly: true,
      ),
      if (_windows)
        UserScript(
          source: qqVerificationViewportScript,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          forMainFrameOnly: true,
        ),
    ]),
    initialSettings: InAppWebViewSettings(
      incognito: true,
      javaScriptEnabled: true,
      domStorageEnabled: true,
      allowFileAccess: false,
      allowContentAccess: false,
      sharedCookiesEnabled: false,
      thirdPartyCookiesEnabled: true,
      useShouldOverrideUrlLoading: true,
      javaScriptCanOpenWindowsAutomatically: false,
      supportMultipleWindows: false,
      userAgent: _userAgent,
      applicationNameForUserAgent: _windows ? null : 'QQMUSIC/140200',
      preferredContentMode: UserPreferredContentMode.MOBILE,
      textZoom: 100,
      useWideViewPort: true,
      loadWithOverviewMode: true,
      builtInZoomControls: false,
      displayZoomControls: false,
    ),
    onWebViewCreated: (controller) => unawaited(_load(controller)),
    onLoadStart: (controller, url) => _remember(url),
    shouldOverrideUrlLoading: (controller, action) async {
      final url = action.request.url;
      if (url == null) return NavigationActionPolicy.CANCEL;
      final uri = Uri.parse(url.toString());
      if (isQqVerificationClose(uri)) {
        if (_challengeSeen) {
          unawaited(_finish());
        } else {
          _complete(null);
        }
        return NavigationActionPolicy.CANCEL;
      }
      return isQqVerificationUri(uri)
          ? NavigationActionPolicy.ALLOW
          : NavigationActionPolicy.CANCEL;
    },
    onLoadStop: (controller, url) async {
      _remember(url);
      if (url != null && isQqVerificationUri(Uri.parse(url.toString()))) {
        try {
          await controller.evaluateJavascript(
            source: qqVerificationProofScript,
          );
          if (_windows) {
            await controller.evaluateJavascript(
              source: qqVerificationViewportScript,
            );
          }
        } catch (_) {}
        final cookie = await _snapshot();
        if (mounted && !_finishing) _lastCookie = cookie;
      }
    },
    onReceivedError: (controller, request, error) {
      if (request.isForMainFrame == true && mounted && !_finishing) {
        setState(() => _error = '验证网页加载失败，请检查网络后重试。');
      }
    },
    onCloseWindow: (controller) {
      if (_challengeSeen) {
        unawaited(_finish());
      } else {
        _complete(null);
      }
    },
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('安全验证')),
    body: SafeArea(
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('请在页面中完成滑块或点选验证。'),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = _windows
                    ? constraints.maxWidth.clamp(1.0, 420.0).toDouble()
                    : constraints.maxWidth;
                _resize(Size(width, constraints.maxHeight));
                return Align(
                  alignment: Alignment.topCenter,
                  child: SizedBox(
                    width: width,
                    height: constraints.maxHeight,
                    child: Stack(
                      children: [
                        if (_ready)
                          Positioned.fill(child: _browser())
                        else
                          const Center(child: CircularProgressIndicator()),
                        if (_error != null)
                          Positioned.fill(
                            child: ColoredBox(
                              color: Theme.of(context).colorScheme.surface,
                              child: Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(24),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(_error!),
                                      const SizedBox(height: 16),
                                      OutlinedButton(
                                        onPressed: _retry,
                                        child: const Text('重试'),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _ready && !_finishing
                    ? () => unawaited(_finish())
                    : null,
                child: Text(_finishing ? '正在继续…' : '完成验证后继续'),
              ),
            ),
          ),
        ],
      ),
    ),
  );

  @override
  void dispose() {
    final environment = _environment;
    final profile = _profile;
    unawaited(() async {
      try {
        await _cookies?.deleteAllCookies();
        await environment?.dispose();
        if (profile != null) {
          final root = Directory.systemTemp.absolute.path;
          if (profile.absolute.path.startsWith(
                '$root${Platform.pathSeparator}motif-qq-verification-',
              ) &&
              await profile.exists()) {
            await profile.delete(recursive: true);
          }
        }
      } catch (_) {}
    }());
    super.dispose();
  }
}
