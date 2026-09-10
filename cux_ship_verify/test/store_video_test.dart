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
      const huge = VideoInfo(
        width: 886,
        height: 1920,
        duration: Duration(seconds: 20),
        frameRate: 30,
        codec: 'avc1',
        container: VideoContainer.mp4,
        fileSize: 501 * 1024 * 1024,
      );
      final problem = videoEncodingProblem(huge, appStorePreviewRules)!;
      expect(problem, contains('501.0 MB'));
      expect(problem, contains('500.0 MB'));
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
