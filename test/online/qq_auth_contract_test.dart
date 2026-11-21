import 'package:flutter_test/flutter_test.dart';

import 'qq_auth_contract_checks.dart';

void main() {
  for (final check in qqAuthChecks().entries) {
    test(check.key, check.value);
  }
}
