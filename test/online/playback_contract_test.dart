import 'package:flutter_test/flutter_test.dart';

import 'playback_contract_checks.dart';

void main() {
  for (final check in playbackContractChecks().entries) {
    test(check.key, check.value);
  }
}
