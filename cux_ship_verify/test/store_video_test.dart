// SPDX-License-Identifier: Apache-2.0
//
// Apple validates a preview after it has been uploaded, and then takes up to
// twenty-four hours to say so — during which the version it hangs off cannot
// be submitted. So every rule here is one that costs a day to learn from
// Apple and a second to learn from a file on disk.
//
// The fixture is built rather than committed, and lives in video_fixture.dart
// because the tree loader's suite needs the same one — see its header.
import 'package:cux_ship_verify/store_video.dart';
import 'package:test/test.dart';

import 'video_fixture.dart';

/// A valid preview of a stated size.
///
/// Constructed rather than parsed, unlike everything else here: half a
/// gigabyte of fixture is half a gigabyte of memory to assert on one integer,
/// and `fileSize` is the one field the parser copies straight from the length
/// of what it was handed — so a built file would be testing `List.length`.
VideoInfo _sized(int bytes) => VideoInfo(
  width: 886,
  height: 1920,
  duration: const Duration(seconds: 20),
  frameRate: 30,
  codec: 'avc1',
  container: VideoContainer.mp4,
  fileSize: bytes,
  audioChannels: 2,
);

void main() {
  group('reading the container', () {
    test('a well-formed preview reads back what was written', () {
      final video = readVideoInfo(mp4())!;
      expect(video.width, 886);
      expect(video.height, 1920);
      expect(video.codec, 'avc1');
      expect(video.container, VideoContainer.mp4);
      expect(video.duration.inSeconds, 20);
      expect(video.frameRate, closeTo(30, 0.01));
    });

    test('a rotated track reports the size the store will see', () {
      // Stored as a landscape frame with a quarter turn beside it, which is
      // what a portrait screen capture ordinarily is. Read naively it is
      // 1920x886 and refused; read correctly it is the 886x1920 Apple wants.
      final video = readVideoInfo(
        mp4(width: 1920, height: 886, rotated: true),
      )!;
      expect(video.width, 886);
      expect(video.height, 1920);
    });

    test('an audio-first file still finds the video track', () {
      // A stereo track ahead of the picture is ordinary — Apple asks for one.
      // The sound `trak` carries zero dimensions and no video sample format,
      // so reading `trak[0]` would report a 0x0 preview with no codec: two
      // refusals for a file that is fine.
      final video = readVideoInfo(mp4(soundTrackFirst: true))!;
      expect(video.width, 886);
      expect(video.height, 1920);
      expect(video.codec, 'avc1');
    });

    test('something that is not a video reads as null, not as invalid', () {
      expect(readVideoInfo([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0]), isNull);
      expect(readVideoInfo(const []), isNull);
    });

    test('an ftyp with no moov behind it reads as null', () {
      // A file whose moov trails the media data and did not arrive.
      final truncated = readVideoInfo(mp4().sublist(0, 24));
      expect(truncated, isNull);
    });

    test('a 64-bit box size near the int64 ceiling reads as null', () {
      // **`offset + size > to` overflows and the guard passes.** With `size`
      // just under 2^63 the sum wraps negative, `> to` is false, and
      // `offset += size` then indexes the buffer at a negative offset — a
      // RangeError escaping a metadata loader rather than the null this
      // returns for anything it cannot read. `size > to - offset` cannot
      // overflow: both sides are non-negative and `to` is a real length.
      // **The overflowing box has to be one the walk skips**, which is the
      // part the first version of this test got wrong. If it is the box being
      // sought, the walk returns it and the bogus `end` merely makes the next
      // `_findBox` loop not execute — null, with or without the guard, so the
      // test passed against the unfixed parser. Skipping it is what performs
      // `offset += size`, wraps the offset negative, and indexes the buffer
      // there on the following iteration.
      final file = <int>[
        ...[0, 0, 0, 16], ...'ftyp'.codeUnits, ...List<int>.filled(8, 0),
        // size == 1 means "the real size is the 64-bit value that follows".
        ...[0, 0, 0, 1], ...'free'.codeUnits,
        ...[0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xF0],
      ];
      expect(readVideoInfo(file), isNull);
    });

    test('an stsd with no entries does not read the next box as a codec', () {
      // Bounded against the file rather than the box, an empty `stsd` is
      // exactly 16 bytes, so `stsd.start + 12` lands in the *sibling* box's
      // header — reporting `stts` as the codec, in a refusal that reads like a
      // real verdict about the file.
      final video = readVideoInfo(mp4(emptyStsd: true));
      expect(video, isNull);
    });

    test('an stts whose products overflow reads as null', () {
      // `count` and `delta` are each unsigned 32-bit as the file states them,
      // so `ticks += count * delta` can overflow int64 and come back negative
      // — and a negative frame rate passes a `> 30` ceiling silently, then
      // becomes a divisor in previewFrameOffset. Crafted, not corruption, but
      // "null when the file cannot be read" is this function's whole contract.
      // 0xFFFFFFFF squared is 1.8e19 and int64 tops out at 9.2e18, so this
      // wraps on the first run. (0x7FFFFFFF squared, twice, lands just *under*
      // the ceiling — which is how the first version of this test passed
      // against the unfixed parser and proved nothing.)
      final video = readVideoInfo(
        mp4(
          sttsRuns: [
            [0xFFFFFFFF, 0xFFFFFFFF],
          ],
        ),
      );
      expect(video, isNull);
    });

    test('a moov truncated mid-tree reads as null rather than throwing', () {
      // **The case the box-length check is actually for**, and the one the
      // test above does not reach: cut inside `moov`, so the outer box
      // declares a length that runs past the end of the file. Without the
      // bounds check `_findBox` hands back a payload range extending past the
      // buffer and the reads inside it go out of range — a RangeError out of
      // a metadata loader, rather than "this is not a video I can read".
      //
      // The previous version of this test truncated at 24 bytes, before
      // `moov` began. That returns null whether the check is there or not,
      // so it passed for a reason unrelated to the guard — found by
      // reverting the guard and watching it stay green.
      final whole = mp4();
      expect(readVideoInfo(whole), isNotNull, reason: 'the control');
      expect(readVideoInfo(whole.sublist(0, whole.length - 40)), isNull);
    });
  });

  group('what Apple refuses, said offline', () {
    test('a valid preview has no problem', () {
      final video = readVideoInfo(mp4())!;
      expect(videoEncodingProblem(video, appStorePreviewRules), isNull);
    });

    test('a silent cut is refused, and the message says so plainly', () {
      // **The 422 this exists to replace.** A silent cut was refused by Apple
      // with `MOV_RESAVE_STEREO` — a channel-layout code — for a file with no
      // audio stream at all, after the upload and a round trip through the
      // ingestion queue. Repeating Apple's word would be repeating a term for
      // something the file does not have.
      final video = readVideoInfo(mp4(audioChannels: 0))!;
      expect(video.audioChannels, 0);
      final problem = videoEncodingProblem(video, appStorePreviewRules)!;
      expect(problem, contains('no audio track'));
      expect(problem, contains('stereo'));
      // Named so that somebody who has *already* had the 422 can connect the
      // two without guessing.
      expect(problem, contains('MOV_RESAVE_STEREO'));
    });

    test('a mono track is refused and says how many it found', () {
      final video = readVideoInfo(mp4(audioChannels: 1))!;
      final problem = videoEncodingProblem(video, appStorePreviewRules)!;
      expect(problem, contains('1 audio channel'));
      expect(problem, isNot(contains('channels')));
    });

    test('a store with no audio rule refuses nothing on audio', () {
      // `requiredAudioChannels` is nullable because inventing a requirement
      // refuses a file nobody's rules refuse — the same reason the file-size
      // ambiguity is a flag rather than a constant.
      const noRule = VideoRules(
        store: 'a store with no opinion',
        codecs: {'avc1': 'H.264'},
        maxFrameRate: 30,
        minDuration: Duration(seconds: 15),
        maxDuration: Duration(seconds: 30),
        maxFileSize: 500 * 1000 * 1000,
      );
      final silent = readVideoInfo(mp4(audioChannels: 0))!;
      expect(videoEncodingProblem(silent, noRule), isNull);
    });

    test('HEVC is named, and so is what Apple takes instead', () {
      final video = readVideoInfo(mp4(codec: 'hvc1'))!;
      final problem = videoEncodingProblem(video, appStorePreviewRules)!;
      expect(problem, contains('hvc1 (HEVC)'));
      expect(problem, contains('H.264'));
    });

    test('too short says how long it is and what the window is', () {
      final video = readVideoInfo(mp4(seconds: 10))!;
      final problem = videoEncodingProblem(video, appStorePreviewRules)!;
      expect(problem, contains('10s'));
      expect(problem, contains('15s to 30s'));
    });

    test('too long is refused at the same boundary', () {
      final video = readVideoInfo(mp4(seconds: 31))!;
      expect(
        videoEncodingProblem(video, appStorePreviewRules),
        contains('31s'),
      );
    });

    test('the duration window is inclusive at both ends', () {
      // 15 and 30 exactly are what Apple states, so both are accepted — an
      // exclusive bound here would refuse the 30-second cut this feature was
      // written for.
      for (final seconds in [15.0, 30.0]) {
        final video = readVideoInfo(mp4(seconds: seconds))!;
        expect(
          videoEncodingProblem(video, appStorePreviewRules),
          isNull,
          reason: '$seconds seconds is inside Apple\'s window',
        );
      }
    });

    test('60 fps is refused and 30 is not', () {
      final fast = readVideoInfo(mp4(frameRate: 60))!;
      final problem = videoEncodingProblem(fast, appStorePreviewRules)!;
      expect(problem, contains('fps'));
      expect(problem, contains('60'));

      final ok = readVideoInfo(mp4(frameRate: 30))!;
      expect(videoEncodingProblem(ok, appStorePreviewRules), isNull);
    });

    test('a hair over 30 fps is not a rule Apple has', () {
      // 29.97 and the rounding of a 600-tick timescale both land either side
      // of 30. Refusing those would be this check inventing a limit, and the
      // cost of that mistake is somebody re-encoding a valid file.
      final video = readVideoInfo(mp4(frameRate: 29.97))!;
      expect(videoEncodingProblem(video, appStorePreviewRules), isNull);
    });

    test('over 500 MB is refused before the upload starts', () {
      // The one rule whose whole value is being asked *first*: Apple's answer
      // arrives after half a gigabyte has been sent.
      //
      // Constructed rather than parsed, unlike every other case here. Half a
      // gigabyte of fixture is half a gigabyte of memory to assert on a
      // single integer, and `fileSize` is the one field the parser copies
      // straight from the length of what it was handed — so a built file
      // would be testing `List.length`.
      final problem = videoEncodingProblem(
        _sized(600 * 1000 * 1000),
        appStorePreviewRules,
      )!;
      expect(problem, contains('600.0 MB'));
      expect(problem, contains('500.0 MB'));
    });

    test('the limit and the message are read in the same base', () {
      // Apple writes "500MB" and states no units. Whichever reading is taken,
      // the cap in the message has to be rendered in it — a decimal limit
      // divided by 1024*1024 renders as "476.8 MB", so the file is refused for
      // exceeding a number nobody was ever told.
      expect(
        videoEncodingProblem(_sized(600 * 1000 * 1000), appStorePreviewRules),
        contains('at most 500.0 MB'),
      );
    });

    test('a file between the two readings of "500MB" says so', () {
      // 510 MB decimal is over 500,000,000 and under 500 MiB (524,288,000).
      // The decimal reading is taken because the errors are not symmetric —
      // a needless re-encode against a day in the ingestion queue — but in
      // this band the rule is ours rather than Apple's, and saying so is the
      // difference between a precaution and a requirement.
      //
      // Constructed rather than built: no fixture discriminates here without
      // half a gigabyte on disk, which is why the consumer's real 473 MB
      // ProRes could not settle it either.
      final problem = videoEncodingProblem(
        _sized(510 * 1000 * 1000),
        appStorePreviewRules,
      )!;
      expect(problem, contains('without units'));
      expect(problem, contains('may well be accepted'));
    });

    test('a file just over the cap is not refused for exceeding itself', () {
      // `_megabytes` rounds to one decimal, so everything in the first 50 kB
      // above the limit rendered as `is 500.0 MB; ... at most 500.0 MB` — the
      // same class of nonsense as comparing two different bases, which this
      // message was already fixed for once. Bytes below that threshold.
      final problem = videoEncodingProblem(
        _sized(500 * 1000 * 1000 + 1),
        appStorePreviewRules,
      )!;
      expect(problem, contains('500000001 bytes'));
      expect(problem, contains('500000000 bytes'));
    });

    test('a file over both readings does not hedge', () {
      // 600 MB is over 524,288,000 too, so there is nothing uncertain about
      // it and the message should not offer false hope.
      final problem = videoEncodingProblem(
        _sized(600 * 1000 * 1000),
        appStorePreviewRules,
      )!;
      expect(problem, isNot(contains('may well be accepted')));
    });

    test('the codec is checked before the duration', () {
      // Order matters for the message rather than for correctness: a file
      // that is wrong twice should say the thing that is hardest to see from
      // looking at it, and a duration is visible in any player.
      final video = readVideoInfo(mp4(codec: 'hvc1', seconds: 5))!;
      expect(
        videoEncodingProblem(video, appStorePreviewRules),
        contains('HEVC'),
      );
    });
  });
}
