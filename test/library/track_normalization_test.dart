import 'package:flutter_test/flutter_test.dart';
import 'package:motif/library/domain/track_normalization.dart';

void main() {
  test('retrieval keys fold width, casing and repeated whitespace', () {
    expect(TrackNormalization.key('  ＳＯＮＧ　 Name\t '), 'song name');
    expect(TrackNormalization.key(' 夜曲 '), '夜曲');
    expect(TrackNormalization.key(' \n\t '), isEmpty);
  });

  test('version markers and script distinctions are preserved', () {
    expect(TrackNormalization.key('Song (Live)'), isNot('song'));
    expect(TrackNormalization.key('Song - Remix'), isNot('song'));
    expect(TrackNormalization.key('Song (伴奏)'), isNot('song'));
    expect(TrackNormalization.key('後來'), isNot(TrackNormalization.key('后来')));
    expect(TrackNormalization.key('Beyoncé'), isNot('beyonce'));
  });
}
