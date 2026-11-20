/// Audio formats included in the first local-library scan pass.
///
/// This is a discovery filter only. It does not guarantee that every codec in
/// a given container can be decoded by the playback engine.
const audioFileExtensions = <String>{
  'm4a',
  'ogg',
  'oga',
  'mp3',
  'flac',
  'wav',
  'aac',
  'alac',
  'ape',
  'opus',
  'wma',
};

String audioExtensionOf(String fileName) {
  final dot = fileName.lastIndexOf('.');
  if (dot < 0 || dot == fileName.length - 1) return '';
  return fileName.substring(dot + 1).toLowerCase();
}

bool isSupportedAudioFileName(String fileName) =>
    audioFileExtensions.contains(audioExtensionOf(fileName));
