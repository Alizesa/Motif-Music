import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:material_ui/material_ui.dart';

import '../../online/qq/auth/qq_credential.dart';
import '../../online/qq/auth/qq_login_protocol.dart';

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
  bool _ready = false;
  bool _finishing = false;
  bool _challengeSeen = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    try {
      if (!isQqVerificationUri(widget.challenge.uri)) {
        throw const FormatException();
      }
      if (defaultTargetPlatform == TargetPlatform.windows) {
        _profile = await Directory.systemTemp.createTemp(
          'motif-qq-verification-',
        );
        _environment = await WebViewEnvironment.create(
          settings: WebViewEnvironmentSettings(userDataFolder: _profile!.path),
        );
      }
      _cookies = CookieManager.instance(webViewEnvironment: _environment);
      if (mounted) setState(() => _ready = true);
    } catch (_) {
      if (mounted) {
        setState(() => _error = '验证窗口暂时无法启动，请检查网络与系统 WebView 组件后重试。');
      }
    }
  }

  Future<void> _load(InAppWebViewController controller) async {
    _web = controller;
    controller.addJavaScriptHandler(
      handlerName: 'motifQqProof',
      callback: (args) async {
        final uri = await controller.getUrl();
        if (!mounted ||
            uri == null ||
            !isQqVerificationUri(Uri.parse(uri.toString()))) {
          return;
        }
        if (args.isEmpty || args.first is! Map) return;
        final data = args.first as Map;
        if (data['kind'] == 'shown') {
          _challengeSeen = true;
          return;
        }
        if (data['kind'] == 'cancel') {
          if (mounted) Navigator.of(context).pop();
          return;
        }
        if (data['kind'] == 'complete') await _finish();
        if (data['kind'] == 'closed' && _challengeSeen) await _finish();
      },
    );
    try {
      if (defaultTargetPlatform == TargetPlatform.windows) {
        await controller.callDevToolsProtocolMethod(
          methodName: 'Network.enable',
        );
      }
      await _cookies!.deleteAllCookies();
      final targets = {widget.challenge.uri.toString()};
      if (widget.challenge.uri.host == 'qq.com' ||
          widget.challenge.uri.host.endsWith('.qq.com')) {
        targets.addAll(['https://y.qq.com/', 'https://c.y.qq.com/']);
      }
      for (final target in targets) {
        for (final entry in qqCookieValues(widget.challenge.cookie).entries) {
          if (defaultTargetPlatform == TargetPlatform.windows) {
            await controller.callDevToolsProtocolMethod(
              methodName: 'Network.setCookie',
              parameters: {
                'url': target,
                'name': entry.key,
                'value': entry.value,
                'path': '/',
                'secure': true,
              },
            );
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

  Future<void> _finish() async {
    if (_finishing || !mounted || _cookies == null) return;
    _finishing = true;
    try {
      final current = await _web?.getUrl();
      final targets = {
        widget.challenge.uri.toString(),
        'https://y.qq.com/',
        'https://c.y.qq.com/',
      };
      if (current != null &&
          isQqVerificationUri(Uri.parse(current.toString()))) {
        targets.add(current.toString());
      }
      var cookie = widget.challenge.cookie;
      if (defaultTargetPlatform == TargetPlatform.windows) {
        final response = await _web!.callDevToolsProtocolMethod(
          methodName: 'Network.getCookies',
          parameters: {'urls': targets.toList()},
        );
        final decoded = response is String ? jsonDecode(response) : response;
        if (decoded is Map && decoded['cookies'] is List) {
          cookie = mergeQqCookies(
            cookie,
            qqCookieHeader({
              for (final value in decoded['cookies'] as List)
                if (value is Map &&
                    value['name'] is String &&
                    value['value'] is String)
                  value['name'] as String: value['value'] as String,
            }),
          );
        }
        if (mounted) {
          Navigator.of(context).pop(QqVerificationResult(cookie: cookie));
        }
        return;
      }
      for (final target in targets) {
        final values = await _cookies!.getCookies(
          url: WebUri(target),
          webViewController: _web,
        );
        cookie = mergeQqCookies(
          cookie,
          qqCookieHeader({for (final value in values) value.name: value.value}),
        );
      }
      if (mounted) {
        Navigator.of(context).pop(QqVerificationResult(cookie: cookie));
      }
    } catch (_) {
      if (mounted) setState(() => _error = '无法读取验证结果，请重新完成验证。');
      _finishing = false;
    }
  }

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
            child: _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_error!),
                          const SizedBox(height: 16),
                          OutlinedButton(
                            onPressed: () {
                              setState(() => _error = null);
                              if (_web != null) {
                                unawaited(_web!.reload());
                              } else {
                                unawaited(_prepare());
                              }
                            },
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    ),
                  )
                : !_ready
                ? const Center(child: CircularProgressIndicator())
                : InAppWebView(
                    webViewEnvironment: _environment,
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
                      applicationNameForUserAgent: 'QQMUSIC/140200',
                    ),
                    onWebViewCreated: (controller) =>
                        unawaited(_load(controller)),
                    shouldOverrideUrlLoading: (controller, action) async {
                      final url = action.request.url;
                      if (url == null) return NavigationActionPolicy.CANCEL;
                      final uri = Uri.parse(url.toString());
                      if (isQqVerificationClose(uri)) {
                        if (_challengeSeen) {
                          unawaited(_finish());
                        } else if (mounted) {
                          Navigator.of(context).pop();
                        }
                        return NavigationActionPolicy.CANCEL;
                      }
                      return isQqVerificationUri(uri)
                          ? NavigationActionPolicy.ALLOW
                          : NavigationActionPolicy.CANCEL;
                    },
                    onLoadStop: (controller, url) async {
                      if (url != null &&
                          isQqVerificationUri(Uri.parse(url.toString()))) {
                        await controller.evaluateJavascript(
                          source: _proofListener,
                        );
                      }
                    },
                    onReceivedError: (controller, request, error) {
                      if (request.isForMainFrame == true && mounted) {
                        setState(() => _error = '验证网页加载失败，请检查网络后重试。');
                      }
                    },
                    onCloseWindow: (controller) {
                      if (_challengeSeen) {
                        unawaited(_finish());
                      } else if (mounted) {
                        Navigator.of(context).pop();
                      }
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
                child: const Text('已完成验证，继续'),
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

// Observe the human-completed official challenge; never solve or submit it.
const _proofListener = r'''
(function(){
  if(window.__motifProof)return; window.__motifProof=true;
  var seen=false,done=false;
  function send(kind){if(done&&kind!=='shown')return; if(kind!=='shown')done=true;
    window.flutter_inappwebview.callHandler('motifQqProof',{kind:kind});}
  function inspect(){
    var frames=document.querySelectorAll('iframe[src*="captcha" i],iframe[src*="verify" i],[id*="captcha" i]');
    for(var i=0;i<frames.length;i++){var r=frames[i].getBoundingClientRect();
      if(r.width>80&&r.height>80&&!seen){seen=true;send('shown');}}
  }
  window.addEventListener('message',function(event){
    if(!/^https:\/\/([a-z0-9-]+\.)*(captcha\.qq\.com|captcha\.qcloud\.com)$/i.test(event.origin))return;
    var data=event.data;try{if(typeof data==='string')data=JSON.parse(data);}catch(e){return;}
    if(data&&data.data)data=data.data;if(!data)return;
    if(Number(data.ret)===0&&data.ticket&&data.randstr)send('complete');
    if(Number(data.ret)===2)send('cancel');
  });
  window.close=function(){send(seen?'closed':'cancel');};
  new MutationObserver(inspect).observe(document.documentElement,{childList:true,subtree:true});inspect();
})();
''';
