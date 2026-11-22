import 'dart:async';
import 'dart:convert';

import 'qq_credential.dart';
import 'qq_login_protocol.dart';

typedef QqDevToolsCall = Future<Object?> Function(
  String method,
  Map<String, Object?> parameters,
);

String qqVerificationMobileUserAgent(String original) {
  var value = original.trim();
  if (value.isEmpty) {
    value =
        'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';
  } else {
    value = value.replaceFirst(RegExp(r'\([^)]*\)'), '(Linux; Android 14)');
    if (!value.contains('Mobile')) {
      value = value.replaceFirst('Safari/', 'Mobile Safari/');
    }
  }
  return value.contains('QQMUSIC/') ? value : '$value QQMUSIC/140200';
}

Map<String, Object?> qqVerificationDeviceMetrics(int width, int height) => {
  'width': width.clamp(1, 4096),
  'height': height.clamp(1, 4096),
  'deviceScaleFactor': 1,
  'mobile': true,
};

Object? _decode(Object? value) {
  if (value is String) {
    if (value.length > 1048576) return null;
    try {
      return jsonDecode(value);
    } on FormatException {
      return null;
    }
  }
  return value;
}

List? _cookieList(Object? value) {
  var decoded = _decode(value);
  for (var depth = 0; depth < 4; depth++) {
    if (decoded is List) return decoded;
    if (decoded is! Map) return null;
    if (decoded['cookies'] is List) return decoded['cookies'] as List;
    decoded = _decode(decoded['result']);
  }
  return null;
}

String _mergeCookie(String cookie, Object? name, Object? value) {
  if (name is! String ||
      value is! String ||
      !RegExp(r'^[A-Za-z0-9_-]{1,80}$').hasMatch(name) ||
      value.length > 8192 ||
      RegExp(r'[;\x00-\x20\x7f]').hasMatch(value)) {
    return cookie;
  }
  try {
    return mergeQqCookies(cookie, '$name=$value');
  } catch (_) {
    return cookie;
  }
}

/// A snapshot is proof context, not a verdict. The original request is retried
/// once by its caller; a closed/unavailable WebView cannot turn success into a
/// client-side verification error.
Future<String> collectQqWindowsVerificationCookies({
  required String fallback,
  required List<String> urls,
  required QqDevToolsCall call,
  Duration timeout = const Duration(seconds: 2),
}) async {
  for (final method in ['Network.getCookies', 'Network.getAllCookies']) {
    try {
      final response = await call(
        method,
        method == 'Network.getCookies' ? {'urls': urls} : {},
      ).timeout(timeout);
      final values = _cookieList(response);
      if (values == null || values.isEmpty) continue;
      var cookie = fallback;
      for (final value in values.take(256)) {
        if (value is! Map) continue;
        if (method == 'Network.getAllCookies') {
          final rawDomain = value['domain'];
          if (rawDomain is! String) continue;
          final domain = rawDomain
              .replaceFirst(RegExp(r'^\.+'), '')
              .toLowerCase();
          if (!isQqVerificationUri(Uri.https(domain, '/')) ||
              !urls.any((url) {
                final host = Uri.tryParse(url)?.host ?? '';
                return host == domain || host.endsWith('.$domain');
              })) {
            continue;
          }
        }
        cookie = _mergeCookie(cookie, value['name'], value['value']);
      }
      return cookie;
    } catch (_) {
      // Use the current private context's alternate method, then the last
      // snapshot. Never read a different WebView/browser profile.
    }
  }
  return fallback;
}

Future<String> collectQqAndroidVerificationCookies({
  required String fallback,
  required List<String> urls,
  required Future<Map<String, String>> Function(String url) read,
  Duration timeout = const Duration(seconds: 2),
}) async {
  var cookie = fallback;
  for (final url in urls) {
    try {
      final values = await read(url).timeout(timeout);
      for (final value in values.entries) {
        cookie = _mergeCookie(cookie, value.key, value.value);
      }
    } catch (_) {
      // A closing page may no longer expose its URL/cookies. Preserve the
      // captured context and let the server decide on the one explicit retry.
    }
  }
  return cookie;
}

const qqVerificationViewportScript = r'''
(function(){
  if(location.protocol!=='https:'||
     !/(^|\.)(qq\.com|qcloud\.com|tencent\.com)$/i.test(location.hostname))return;
  function apply(){
    var meta=document.querySelector('meta[name="viewport"]');
    if(!meta){meta=document.createElement('meta');meta.name='viewport';document.head.appendChild(meta);}
    meta.content='width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no';
    document.documentElement.style.webkitTextSizeAdjust='100%';
    document.documentElement.style.textSizeAdjust='100%';
  }
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',apply,{once:true});
  else apply();
})();
''';

const qqVerificationProofScript = r'''
(function(){
  if(location.protocol!=='https:'||
     !/(^|\.)(qq\.com|qcloud\.com|tencent\.com)$/i.test(location.hostname)||
     window.__motifProof)return;
  window.__motifProof=true;
  var seen=false,done=false,human=false,pending=0,readyAt=0,lastEnd=0;
  var finishTimer=0,bridgeTimer=0,inspectTimer=0,kind='closed',queue=[];
  function flush(){
    var bridge=window.flutter_inappwebview;
    if(!bridge||typeof bridge.callHandler!=='function'){
      if(queue.length&&!bridgeTimer)bridgeTimer=window.setTimeout(function(){bridgeTimer=0;flush();},100);
      return;
    }
    if(bridgeTimer)window.clearTimeout(bridgeTimer);bridgeTimer=0;
    while(queue.length)bridge.callHandler('motifQqProof',{kind:queue.shift()});
  }
  function send(value){queue.push(value);flush();}
  function finish(value){
    if(done)return;done=true;
    if(finishTimer)window.clearTimeout(finishTimer);
    if(inspectTimer)window.clearInterval(inspectTimer);
    send(value);
  }
  function visible(){
    var nodes=document.querySelectorAll(
      'iframe[src*="captcha" i],iframe[src*="turing" i],iframe[src*="verify" i],'+
      '[id*="captcha" i],[class*="captcha" i],[id*="verify" i],[class*="verify" i]');
    for(var i=0;i<nodes.length;i++){
      var rect=nodes[i].getBoundingClientRect(),style=window.getComputedStyle(nodes[i]);
      if(style.display!=='none'&&style.visibility!=='hidden'&&Number(style.opacity||1)>0.01&&
         rect.width>80&&rect.height>80)return true;
    }
    return false;
  }
  function shown(){if(!seen){seen=true;send('shown');}}
  function settle(){
    finishTimer=0;if(done)return;
    var elapsed=Date.now()-readyAt;
    if(elapsed<700||((pending>0||Date.now()-lastEnd<200)&&elapsed<3000)){
      finishTimer=window.setTimeout(settle,100);return;
    }
    finish(kind);
  }
  function schedule(value){
    if(done)return;kind=value;
    if(!readyAt)readyAt=Date.now();
    if(!finishTimer)finishTimer=window.setTimeout(settle,700);
  }
  function inspect(){
    if(done)return;
    if(visible()){
      shown();
      if(!human&&finishTimer){window.clearTimeout(finishTimer);finishTimer=0;readyAt=0;}
    }else if(seen)schedule(human?'complete':'closed');
  }
  function ended(){pending=Math.max(0,pending-1);lastEnd=Date.now();}
  if(window.XMLHttpRequest&&window.XMLHttpRequest.prototype){
    var originalSend=window.XMLHttpRequest.prototype.send;
    window.XMLHttpRequest.prototype.send=function(){
      pending++;var once=false;
      function stop(){if(!once){once=true;ended();}}
      this.addEventListener('loadend',stop,{once:true});
      try{return originalSend.apply(this,arguments);}catch(error){stop();throw error;}
    };
  }
  if(typeof window.fetch==='function'){
    var originalFetch=window.fetch;
    window.fetch=function(){
      pending++;
      try{return Promise.resolve(originalFetch.apply(this,arguments)).then(function(value){ended();return value;},
        function(error){ended();throw error;});}catch(error){ended();throw error;}
    };
  }
  window.addEventListener('flutterInAppWebViewPlatformReady',flush);
  window.addEventListener('message',function(event){
    if(done||!/^https:\/\/([a-z0-9-]+\.)*(captcha\.qq\.com|captcha\.qcloud\.com|captcha\.tencent\.com)$/i.test(event.origin))return;
    var data=event.data;try{if(typeof data==='string')data=JSON.parse(data);}catch(error){return;}
    if(data&&data.data&&typeof data.data==='object')data=data.data;
    if(!data||typeof data.ret==='undefined')return;
    if(Number(data.ret)===2){finish('cancel');return;}
    if(Number(data.ret)===0&&data.ticket&&data.randstr){
      human=true;shown();schedule('complete');
    }
  });
  window.close=function(){if(seen)schedule(human?'complete':'closed');else finish('cancel');};
  function install(){
    if(document.documentElement)new MutationObserver(inspect).observe(document.documentElement,
      {childList:true,subtree:true,attributes:true,attributeFilter:['class','style','hidden']});
    inspect();inspectTimer=window.setInterval(inspect,400);
  }
  if(document.documentElement)install();
  else document.addEventListener('DOMContentLoaded',install,{once:true});
})();
''';
