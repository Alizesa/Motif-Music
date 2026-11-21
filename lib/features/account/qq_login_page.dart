import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../online/qq/auth/qq_auth_client.dart';
import '../../online/qq/auth/qq_login_controller.dart';
import '../../online/qq/auth/qq_login_protocol.dart';
import '../../online/qq/auth/qq_session_manager.dart';
import 'qq_verification_page.dart';

class QqLoginPage extends StatefulWidget {
  const QqLoginPage({
    super.key,
    required this.sessions,
    required this.client,
    this.verifier,
  });
  final QqSessionManager sessions;
  final QqAuthClient client;
  final QqVerify? verifier;
  @override
  State<QqLoginPage> createState() => _QqLoginPageState();
}

class _QqLoginPageState extends State<QqLoginPage> {
  late final QqLoginController _login;
  final _phone = TextEditingController();
  final _country = TextEditingController(text: '86');
  final _code = TextEditingController();
  bool _phoneTab = false;
  QqQrMethod _method = QqQrMethod.qq;
  bool _popping = false;
  @override
  void initState() {
    super.initState();
    _login = QqLoginController(
      sessions: widget.sessions,
      client: widget.client,
      verify:
          widget.verifier ??
          (challenge) => showQqVerification(context, challenge),
    )..addListener(_listen);
    unawaited(_login.startQr(_method));
  }

  void _listen() {
    if (_login.status == QqLoginUiStatus.success && !_popping) {
      _popping = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
    }
  }

  @override
  void dispose() {
    _login.removeListener(_listen);
    _login.dispose();
    _phone.dispose();
    _country.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('登录 QQ 音乐')),
    body: SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: AnimatedBuilder(
            animation: _login,
            builder: (context, _) => ListView(
              padding: const EdgeInsets.all(24),
              children: [
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(
                      value: false,
                      label: Text('扫码'),
                      icon: Icon(Icons.qr_code_rounded),
                    ),
                    ButtonSegment(
                      value: true,
                      label: Text('手机号'),
                      icon: Icon(Icons.phone_android_rounded),
                    ),
                  ],
                  selected: {_phoneTab},
                  onSelectionChanged: _login.working
                      ? null
                      : (values) {
                          setState(() => _phoneTab = values.single);
                          if (_phoneTab) {
                            unawaited(_login.startPhone());
                          } else {
                            unawaited(_login.startQr(_method));
                          }
                        },
                ),
                const SizedBox(height: 24),
                if (!_phoneTab) ...[
                  SegmentedButton<QqQrMethod>(
                    segments: const [
                      ButtonSegment(value: QqQrMethod.qq, label: Text('手机 QQ')),
                      ButtonSegment(
                        value: QqQrMethod.wechat,
                        label: Text('微信'),
                      ),
                    ],
                    selected: {_method},
                    onSelectionChanged: _login.working
                        ? null
                        : (values) {
                            setState(() => _method = values.single);
                            unawaited(_login.startQr(_method));
                          },
                  ),
                  const SizedBox(height: 24),
                  Center(
                    child: SizedBox.square(
                      dimension: 240,
                      child: _login.qr == null
                          ? _login.status == QqLoginUiStatus.loading
                                ? const Center(
                                    child: CircularProgressIndicator(),
                                  )
                                : const Icon(Icons.qr_code_rounded, size: 96)
                          : ColoredBox(
                              color: Colors.white,
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Image.memory(
                                  _login.qr!.image,
                                  fit: BoxFit.contain,
                                  errorBuilder: (_, _, _) =>
                                      const Icon(Icons.error_outline_rounded),
                                ),
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(_login.message, textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    key: const Key('qq-refresh-qr'),
                    onPressed: _login.working
                        ? null
                        : () => unawaited(_login.startQr(_method)),
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('刷新二维码'),
                  ),
                ] else ...[
                  Row(
                    children: [
                      SizedBox(
                        width: 96,
                        child: TextField(
                          controller: _country,
                          keyboardType: TextInputType.phone,
                          decoration: const InputDecoration(
                            labelText: '地区码',
                            prefixText: '+',
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          key: const Key('qq-login-phone'),
                          controller: _phone,
                          keyboardType: TextInputType.phone,
                          autofillHints: const [
                            AutofillHints.telephoneNumberNational,
                          ],
                          decoration: const InputDecoration(labelText: '手机号'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    key: const Key('qq-login-code'),
                    controller: _code,
                    keyboardType: TextInputType.number,
                    obscureText: true,
                    autofillHints: const [AutofillHints.oneTimeCode],
                    decoration: const InputDecoration(labelText: '验证码'),
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton(
                    key: const Key('qq-send-code'),
                    onPressed: _login.working || _login.sendWaitSeconds > 0
                        ? null
                        : () => unawaited(
                            _login.sendCode(_phone.text, _country.text),
                          ),
                    child: Text(
                      _login.sendWaitSeconds > 0
                          ? '${_login.sendWaitSeconds} 秒后重试'
                          : '获取验证码',
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    key: const Key('qq-submit-sms'),
                    onPressed: _login.working
                        ? null
                        : () => unawaited(
                            _login.loginPhone(
                              _phone.text,
                              _country.text,
                              _code.text,
                            ),
                          ),
                    child: const Text('登录'),
                  ),
                  if (_login.working)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: LinearProgressIndicator(),
                    ),
                ],
                if (_login.error case final error?) ...[
                  const SizedBox(height: 20),
                  Text(
                    error,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
