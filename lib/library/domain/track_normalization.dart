/// Conservative, versioned retrieval keys, never a proof of song identity.
/// Keep live/remix/acoustic markers, punctuation, accents and script differences.
/// Missing tags remain missing; filenames must not become trusted match keys.
abstract final class TrackNormalization {
  static const version = 1;
  static final _whitespace = RegExp(r'\s+');

  static String key(String value) {
    final widthFolded = String.fromCharCodes(
      value.runes.map((rune) {
        if (rune == 0x3000) return 0x20;
        if (rune >= 0xff01 && rune <= 0xff5e) return rune - 0xfee0;
        return rune;
      }),
    );
    return widthFolded.toLowerCase().trim().replaceAll(_whitespace, ' ');
  }
}
