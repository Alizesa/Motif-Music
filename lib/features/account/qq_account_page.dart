import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../online/qq/auth/qq_auth_error.dart';
import '../../online/qq/auth/qq_session_manager.dart';

class QqAccountPage extends StatefulWidget {
  const QqAccountPage({
    super.key,
    required this.sessions,
    required this.onLogin,
  });
  final QqSessionManager sessions;
  final VoidCallback onLogin;
  @override
  State<QqAccountPage> createState() => _QqAccountPageState();
}

class _QqAccountPageState extends State<QqAccountPage> {
  late final StreamSubscription<QqSessionStatus> _subscription;
  bool _working = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _subscription = widget.sessions.changes.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    unawaited(_subscription.cancel());
    super.dispose();
  }

  Future<void> _logout() async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await widget.sessions.logout();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is QqAuthException
              ? error.toString()
              : '退出失败，请重试。',
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = widget.sessions.account;
    return Scaffold(
      appBar: AppBar(title: const Text('QQ 音乐账号')),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                ListTile(
                  leading: CircleAvatar(
                    backgroundImage: account?.avatar == null
                        ? null
                        : NetworkImage(account!.avatar.toString()),
                    child: account?.avatar == null
                        ? const Icon(Icons.person_outline_rounded)
                        : null,
                  ),
                  title: Text(account?.name ?? '未登录'),
                  subtitle: account == null ? null : Text(account.id),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _working ? null : widget.onLogin,
                  child: Text(account == null ? '登录' : '切换账号'),
                ),
                if (account != null) ...[
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: _working ? null : () => unawaited(_logout()),
                    child: const Text('退出登录'),
                  ),
                ],
                if (_error case final error?) Text(error),
                if (_working) const LinearProgressIndicator(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
