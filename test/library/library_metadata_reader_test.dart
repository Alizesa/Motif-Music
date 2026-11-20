import 'package:flutter_test/flutter_test.dart';
import 'package:motif/library/domain/library_models.dart';
import 'package:motif/library/platform/library_metadata_reader.dart';
import 'package:motif/library/platform/taglib_metadata_reader.dart';

import '../support/library_fixtures.dart';

void main() {
  test('TagLib adapter retains raw text and permits missing tags and unknown duration', () {
    final metadata = metadataFromTagLib({
      'title': ' 原始标题 ',
      'artist': '歌手',
      'album': '专辑',
      'durationMs': 123456,
    });
    expect(metadata.title, ' 原始标题 ');
    expect(metadata.artist, '歌手');
    expect(metadata.album, '专辑');
    expect(metadata.durationMs, 123456);
    expect(metadata.container, isNull);
    expect(metadata.codec, isNull);
    for (final value in [null, 0, -1]) {
      final unknown = metadataFromTagLib({'durationMs': value});
      expect(unknown.title, isEmpty);
      expect(unknown.durationMs, isNull);
      expect(unknown.state, MetadataState.ready);
    }
  });
  test(
    'file stats reject changed, disappearing, or wholly unverifiable data',
    () {
      final observed = testAudio(1);
      final file = LocalAudioFile(
        id: 1,
        location: observed.location,
        fileName: observed.fileName,
        sizeBytes: observed.sizeBytes,
        modifiedMs: observed.modifiedMs,
        metadata: const TrackMetadata(state: MetadataState.pending),
        revision: 1,
        normalizationVersion: 1,
        isPresent: true,
      );
      const state = MetadataFileState(sizeBytes: 42, modifiedMs: 100);
      state.verifyExpected(file);
      state.verifyStable(state);
      expect(
        () => const MetadataFileState(
          sizeBytes: 43,
          modifiedMs: 100,
        ).verifyExpected(file),
        throwsFormatException,
      );
      expect(
        () => const MetadataFileState().verifyExpected(file),
        throwsFormatException,
      );
      expect(
        () => state.verifyStable(const MetadataFileState(sizeBytes: 42)),
        throwsFormatException,
      );
      expect(
        () => const MetadataFileState().verifyStable(const MetadataFileState()),
        throwsFormatException,
      );
      const MetadataFileState(sizeBytes: 42)
          .verifyStable(const MetadataFileState(sizeBytes: 42));
    },
  );
}
