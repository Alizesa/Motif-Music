import 'package:flutter_test/flutter_test.dart';
import 'package:motif/library/domain/audio_quality.dart';
import 'package:motif/library/domain/library_models.dart';
import 'package:motif/library/domain/local_playback_matcher.dart';
import 'package:motif/settings/playback_quality_settings.dart';

const song = TrackMetadata(
  title: 'Song',
  artist: 'Artist',
  album: 'Album',
  durationMs: 180000,
);

LocalAudioFile candidate(
  int id, {
  String title = 'Song',
  String artist = 'Artist',
  String album = 'Album',
  int? durationMs = 180000,
  int? bitrateKbps = 128,
  int? sampleRateHz = 44100,
}) => LocalAudioFile(
  id: id,
  location: FileLocation(
    platform: LibraryPlatform.windows,
    key: '$id',
    locator: 'file:///music/$id.flac',
  ),
  fileName: '$id.flac',
  sizeBytes: 999999,
  modifiedMs: 100,
  metadata: TrackMetadata(
    title: title,
    artist: artist,
    album: album,
    durationMs: durationMs,
    bitrateKbps: bitrateKbps,
    sampleRateHz: sampleRateHz,
    channels: 2,
  ),
  revision: 1,
  normalizationVersion: 1,
  isPresent: true,
);

LocalPlaybackResolution resolve(
  List<LocalAudioFile> files, {
  TrackMetadata track = song,
  PlaybackQualityMode mode = PlaybackQualityMode.highestLocal,
  AudioQuality? onlineQuality,
  bool truncated = false,
}) => const LocalPlaybackMatcher().resolve(
  track: track,
  mode: mode,
  onlineQuality: onlineQuality,
  candidates: MatchCandidates(
    timed: files,
    unmeasured: const [],
    isTruncated: truncated,
  ),
);

void main() {
  test(
    'inclusive five-second tolerance and normalization keep version markers',
    () {
      for (final duration in [175000, 185000]) {
        expect(
          resolve([candidate(1, title: ' Ｓｏｎｇ ', durationMs: duration)])
              .selected
              ?.id,
          1,
        );
      }
      expect(
        resolve([candidate(1, durationMs: 185001)]).status,
        LocalPlaybackStatus.needsConfirmation,
      );
      expect(
        resolve([candidate(1, title: 'Song (Live)')]).status,
        LocalPlaybackStatus.noMatch,
      );
      expect(
        resolve([candidate(1, title: '')]).status,
        LocalPlaybackStatus.noMatch,
      );
    },
  );

  test(
    'missing artist, album, duration and known conflicts require review',
    () {
      for (final file in [
        candidate(1, artist: ''),
        candidate(1, artist: 'Other'),
        candidate(1, album: ''),
        candidate(1, album: 'Live'),
        candidate(1, durationMs: null),
      ]) {
        final result = resolve([file]);
        expect(result.status, LocalPlaybackStatus.needsConfirmation);
        expect(result.candidates, hasLength(1));
        expect(result.selected, isNull);
      }
      expect(
        resolve(
          [candidate(1)],
          track: const TrackMetadata(title: 'Song', durationMs: 180000),
        ).status,
        LocalPlaybackStatus.needsConfirmation,
      );
      expect(
        resolve([candidate(1), candidate(2, durationMs: null)]).selected,
        isNull,
      );
      expect(
        resolve([candidate(1), candidate(2, artist: 'Other')]).selected?.id,
        1,
      );
    },
  );

  test('unique reliable version does not require quality ranking', () {
    expect(
      resolve([
        candidate(1, bitrateKbps: null),
      ], mode: PlaybackQualityMode.followOnline).selected?.id,
      1,
    );
  });

  test('highest local quality wins independent of candidate ordering', () {
    for (final files in [
      [candidate(1), candidate(2, bitrateKbps: 320)],
      [candidate(2, bitrateKbps: 320), candidate(1)],
    ]) {
      final result = resolve(files);
      expect(result.selected?.id, 2);
      expect(result.reason, LocalPlaybackReason.highestQuality);
    }
  });

  test(
    'ties, unknown properties and conflicting metrics block highest selection',
    () {
      for (final files in [
        [candidate(1), candidate(2)],
        [candidate(1, bitrateKbps: 320), candidate(2, bitrateKbps: null)],
        [
          candidate(1, bitrateKbps: 320),
          candidate(2, bitrateKbps: 512, sampleRateHz: 22050),
        ],
      ]) {
        expect(resolve(files).status, LocalPlaybackStatus.needsConfirmation);
      }
    },
  );

  test('follow online chooses matching quality rather than highest local', () {
    final files = [candidate(1), candidate(2, bitrateKbps: 320)];
    expect(
      resolve(
        files,
        mode: PlaybackQualityMode.followOnline,
        onlineQuality: files.first.quality,
      ).selected?.id,
      1,
    );
    expect(
      resolve(
        files,
        mode: PlaybackQualityMode.followOnline,
        onlineQuality: files.last.quality,
      ).selected?.id,
      2,
    );
    expect(
      resolve(files, mode: PlaybackQualityMode.followOnline).reason,
      LocalPlaybackReason.missingOnlineQuality,
    );
    expect(
      resolve(
        files,
        mode: PlaybackQualityMode.followOnline,
        onlineQuality: const AudioQuality(
          bitrateKbps: 192,
          sampleRateHz: 44100,
          channels: 2,
        ),
      ).selected,
      isNull,
    );
    expect(
      resolve(
        [candidate(1), candidate(2, bitrateKbps: null)],
        mode: PlaybackQualityMode.followOnline,
        onlineQuality: files.first.quality,
      ).selected,
      isNull,
    );
  });

  test(
    'truncated candidates cannot establish uniqueness or highest quality',
    () {
      final result = resolve([candidate(1)], truncated: true);
      expect(result.selected, isNull);
      expect(result.isTruncated, isTrue);
      expect(result.reason, LocalPlaybackReason.truncatedCandidates);
    },
  );
}
