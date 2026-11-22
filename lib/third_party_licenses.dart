import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'online/lx/fixture/lx_fixture_runtime.dart' show lxAppFixtureEnabled;

void registerThirdPartyLicenses() {
  LicenseRegistry.addLicense(() async* {
    final text = await rootBundle.loadString('packages/motif_taglib/LICENSE');
    yield LicenseEntryWithLineBreaks(const [
      'TagLib',
      'utfcpp',
      'flutter_taglib configuration headers',
    ], text);
  });
  if (lxAppFixtureEnabled) {
    LicenseRegistry.addLicense(() async* {
      final text = await rootBundle.loadString(
        'tool/lx_prototype/licenses/quickjs-ng/LICENSE',
      );
      yield LicenseEntryWithLineBreaks(const ['QuickJS-NG'], text);
    });
  }
}
