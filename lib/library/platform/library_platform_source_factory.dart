import 'dart:io';

import 'android_saf_library_source.dart';
import 'library_platform_source.dart';
import 'windows_library_source.dart';

LibraryPlatformSource createLibraryPlatformSource() {
  if (Platform.isWindows) return const WindowsLibrarySource();
  if (Platform.isAndroid) return const AndroidSafLibrarySource();
  throw UnsupportedError(
    'Motif local-library scanning supports Windows and Android.',
  );
}
