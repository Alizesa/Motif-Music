enum OnlineErrorKind {
  transport,
  rateLimited,
  rejected,
  malformedResponse,
  unavailable,
  unsupported,
  queueFull,
  closed,
  sessionChanged,
  authenticationRequired,
  sessionExpired,
}

/// Deliberately excludes raw server bodies, URLs and credentials from errors.
class OnlineException implements Exception {
  const OnlineException(this.kind, {this.retryAt});

  final OnlineErrorKind kind;
  final DateTime? retryAt;

  OnlineException withRetryAt(DateTime value) =>
      OnlineException(kind, retryAt: value);

  @override
  String toString() => switch (kind) {
    OnlineErrorKind.transport => '网络请求失败，请稍后重试。',
    OnlineErrorKind.rateLimited => '请求过于频繁，已暂停联网请求。',
    OnlineErrorKind.rejected => '来源拒绝了请求，已暂停继续请求。',
    OnlineErrorKind.malformedResponse => '来源返回的数据不完整。',
    OnlineErrorKind.unavailable => '当前歌曲或所选音质不可用。',
    OnlineErrorKind.unsupported => '当前来源不支持此操作或音质。',
    OnlineErrorKind.queueFull => '待处理请求较多，请稍后重试。',
    OnlineErrorKind.closed => '在线来源已关闭。',
    OnlineErrorKind.sessionChanged => '账号已变化，请重试。',
    OnlineErrorKind.authenticationRequired => '登录后查看为你推荐的音乐。',
    OnlineErrorKind.sessionExpired => '登录已失效，请重新登录。',
  };
}
