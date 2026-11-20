import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

void registerThirdPartyLicenses() {
  LicenseRegistry.addLicense(() async* {
    final text = await rootBundle.loadString('packages/motif_taglib/LICENSE');
    yield LicenseEntryWithLineBreaks(const [
      'TagLib',
      'utfcpp',
      'flutter_taglib configuration headers',
    ], text);
  });
}
