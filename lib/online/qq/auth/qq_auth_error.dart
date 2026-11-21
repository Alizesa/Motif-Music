enum QqAuthErrorKind {
  transport,
  malformed,
  rejected,
  expired,
  invalidCode,
  rateLimited,
  unbound,
  disabled,
  cancelled,
  storage,
}

class QqAuthException implements Exception {
  const QqAuthException(this.kind, {this.apiCode});
  final QqAuthErrorKind kind;
  final int? apiCode;

  @override
  String toString() => switch (kind) {
    QqAuthErrorKind.transport => '登录服务暂时无法连接，请重试。',
    QqAuthErrorKind.malformed => '登录服务返回的信息不完整，请重试。',
    QqAuthErrorKind.rejected => 'QQ 音乐拒绝了登录请求，请重试。',
    QqAuthErrorKind.expired => '登录信息已过期，请重新登录。',
    QqAuthErrorKind.invalidCode => '验证码不正确，请重新输入。',
    QqAuthErrorKind.rateLimited => '请求过于频繁，请稍后再试。',
    QqAuthErrorKind.unbound => '该账号尚未绑定 QQ 音乐。',
    QqAuthErrorKind.disabled => '该账号当前无法登录。',
    QqAuthErrorKind.cancelled => '登录操作已取消。',
    QqAuthErrorKind.storage => '无法访问安全登录存储，请重试。',
  };
}

QqAuthException qqLoginFailure(int code) => QqAuthException(switch (code) {
  1000 || 104400 || 104401 || 301 => QqAuthErrorKind.expired,
  20271 => QqAuthErrorKind.invalidCode,
  100001 || 104604 => QqAuthErrorKind.rateLimited,
  20274 => QqAuthErrorKind.unbound,
  20272 || 20277 || 20278 || 20450 || 20279 => QqAuthErrorKind.disabled,
  _ => QqAuthErrorKind.rejected,
}, apiCode: code);
