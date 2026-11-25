import '../domain/online_error.dart';

enum LxRequestFailure {
  apiAddress,
  mediaAddress,
  privateAddress,
  headers,
  method,
  body,
  budget,
}

/// Fixed reasons only: never include request URLs, header values or bodies.
final class LxRequestException extends OnlineException {
  const LxRequestException(this.reason)
    : super(
        reason == LxRequestFailure.headers ||
                reason == LxRequestFailure.method ||
                reason == LxRequestFailure.body
            ? OnlineErrorKind.unsupportedRequest
            : reason == LxRequestFailure.budget
            ? OnlineErrorKind.operationRejected
            : OnlineErrorKind.rejected,
      );

  final LxRequestFailure reason;

  @override
  String toString() => switch (reason) {
    LxRequestFailure.apiAddress => '音源取址请求的地址不受支持，已拦截该请求。',
    LxRequestFailure.mediaAddress => '音源返回的播放地址不受支持，已停止播放。',
    LxRequestFailure.privateAddress => '音源请求指向非公网地址，已停止继续请求。',
    LxRequestFailure.headers => '音源使用了当前不支持的请求头，请换一个音源。',
    LxRequestFailure.method => '音源使用了当前不支持的请求方法，请换一个音源。',
    LxRequestFailure.body => '音源使用了当前不支持的请求内容，请换一个音源。',
    LxRequestFailure.budget => '音源请求次数达到本次上限，已停止继续请求。',
  };
}
