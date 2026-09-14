// SPDX-License-Identifier: Apache-2.0
//
// The event stream `upload --json` writes, specified in
// docs/design/upload-events.md — which argues the parts a reader of this file
// cannot see: why events rather than percentage lines, why a stream is allowed
// to be written as it happens where every other `--json` document is written
// whole at the end, and why the App Store half carries no byte progress at all.
//
// **The shape is documents.dart's; this file is the emitting.** `PlayUploadEvent`
// and `AppStoreUploadEvent` are the format, dartdoc and all, for the same
// reason every other kind is a class: a consumer decodes with `fromJson`
// against what this writes rather than against a format learned by reading an
// encoder.
//
// **Two emitters rather than one parameterised over a store**, which is the
// same split `play_upload_reuse_test.dart` and `appstore/upload_reuse_test.dart`
// make and for the same reason: the two streams do not carry the same things.
// Play reports bytes and commits a transaction; the App Store reports neither
// and waits on Apple's processing instead. A shared emitter would have to hold
// every field of both and let each store leave half of them null, which is the
// shape `documents.dart` says a format must not have.
import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'appstore/app_store.dart' show AscPlatform;
import 'documents.dart';
import 'json_output.dart';

/// `cux_ship play upload --json`.
///
/// **Silent unless `--json` was asked for.** [out] is null on an ordinary run
/// and every method below returns having written nothing, so the upload path
/// calls these unconditionally rather than wrapping each call in a flag test —
/// which is the shape that goes stale the next time a branch is added.
class PlayUploadEvents {
  PlayUploadEvents(this.out);

  /// Where the lines go, or null when this run prints no events.
  ///
  /// [stdout] on a real `--json` run. The other stream is not an option: the
  /// whole contract is that stdout carries the events and nothing else.
  final IOSink? out;

  /// The upload moved into [state].
  ///
  /// [bytesTotal] is the artifact's size and belongs to
  /// [UploadState.transferring] alone — a reader that has been told how big
  /// the artifact is can say so before the first chunk lands.
  void state(UploadState state, {int? bytesTotal}) => _write(
    PlayUploadEvent(
      schema: playUploadSchema,
      kind: DocumentKind.playUpload,
      event: UploadEvent.state,
      state: state,
      bytesTotal: bytesTotal,
    ),
  );

  /// Play has acknowledged [bytesSent] of [bytesTotal].
  ///
  /// Called from [observeChunks], which is the only thing that knows — see
  /// there for why this is not counted off the artifact as it is read.
  void progress({required int bytesSent, required int bytesTotal}) => _write(
    PlayUploadEvent(
      schema: playUploadSchema,
      kind: DocumentKind.playUpload,
      event: UploadEvent.progress,
      bytesSent: bytesSent,
      bytesTotal: bytesTotal,
    ),
  );

  /// The run finished. The last line of the stream.
  void result({
    required String packageName,
    required String track,
    required String versionName,
    required int? versionCode,
    required bool committed,
  }) => _write(
    PlayUploadEvent(
      schema: playUploadSchema,
      kind: DocumentKind.playUpload,
      event: UploadEvent.result,
      result: PlayUploadResult(
        packageName: packageName,
        track: track,
        versionName: versionName,
        versionCode: versionCode,
        committed: committed,
      ),
    ),
  );

  /// [client], wrapped so that every resumable chunk Play acknowledges becomes
  /// a [progress] line and the final one becomes [UploadState.accepting].
  ///
  /// Returns [client] itself when this run emits no events, so an ordinary run
  /// carries no wrapper at all.
  http.Client observeChunks(http.Client client) =>
      out == null ? client : ResumableChunkObserver(client, this);

  void _write(PlayUploadEvent event) {
    final sink = out;
    if (sink != null) {
      writeJsonEvent(sink, event);
    }
  }
}

/// `cux_ship appstore upload --json`.
///
/// The Play emitter's twin, minus the one thing this stream cannot say — see
/// [AppStoreUploadEvent], which carries the argument.
class AppStoreUploadEvents {
  AppStoreUploadEvents(this.out);

  /// Where the lines go, or null when this run prints no events.
  final IOSink? out;

  /// The upload moved into [state].
  void state(UploadState state, {int? bytesTotal}) => _write(
    AppStoreUploadEvent(
      schema: appStoreUploadSchema,
      kind: DocumentKind.appStoreUpload,
      event: UploadEvent.state,
      state: state,
      bytesTotal: bytesTotal,
    ),
  );

  /// The run finished. The last line of the stream.
  void result({
    required String bundleId,
    required AscPlatform platform,
    required String? versionName,
    required String? buildNumber,
    required bool waitedForProcessing,
  }) => _write(
    AppStoreUploadEvent(
      schema: appStoreUploadSchema,
      kind: DocumentKind.appStoreUpload,
      event: UploadEvent.result,
      result: AppStoreUploadResult(
        bundleId: bundleId,
        platform: platform,
        versionName: versionName,
        buildNumber: buildNumber,
        waitedForProcessing: waitedForProcessing,
      ),
    ),
  );

  void _write(AppStoreUploadEvent event) {
    final sink = out;
    if (sink != null) {
      writeJsonEvent(sink, event);
    }
  }
}

/// The `bytes <start>-<end>/<total>` header a resumable chunk carries.
///
/// Anchored at both ends, and `<total>` is `\d+` rather than anything looser,
/// because googleapis sends a literal `*` for an upload whose length it does
/// not know — and a percentage against an unknown total is not a percentage.
/// Every upload here passes `Media(..., length)`, so the `*` form never
/// arrives; not matching it is what makes that an assumption this file states
/// rather than one it relies on.
final _contentRange = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$');

/// Reports each chunk of a resumable upload that the store has taken.
///
/// **The signal is Google's acknowledgement, not this package's count**, and
/// that is the whole design. The obvious alternative — wrapping the artifact's
/// byte stream and counting what is read out of it — was rejected twice over:
///
///   - It measures bytes handed to the uploader rather than bytes the store
///     holds, so it runs ahead of the socket by however much is buffered.
///   - Its offsets start at zero. A resumable upload that **resumes** picks up
///     at the offset the store already has, and a counter would report the
///     first chunk after a resume as a jump from zero — reading the offset off
///     the wire is what makes it absolute instead.
///
/// What is observed is the protocol googleapis speaks and this package does
/// not: one `PUT` per chunk carrying a `Content-Range` naming the bytes it
/// holds, answered `308` while there is more to come and `200`/`201` for the
/// last one. So a line is written when a chunk **completes**, never on a
/// timer — a tick driven by a clock turns at the same rate whether the socket
/// is moving or dead, which is exactly the failure this stream exists to make
/// visible.
///
/// **The coalescing is the protocol's too.** A chunk is 1 MiB, so a 68 MB
/// bundle is about sixty-eight lines — tens rather than thousands — with no
/// threshold of this package's own to pick, tune, or get wrong.
///
/// **A progress line needs no de-duplication and the `accepting` line does,
/// and the difference is which side of the request each is written on.**
/// googleapis retries a chunk only on `500`, `502` and `503`, which the status
/// check below already drops — so a *progress* line, written after the
/// response, cannot report one range twice. A guard for that was written first
/// and removed, because nothing could reach it.
///
/// [UploadState.accepting] is written **before** the request, which is the
/// whole point of it, and a retry sends the final chunk again: without
/// [_announcedAccepting] a 5xx on that chunk announces the same wait two or
/// three times. [UploadEvent.result]'s contract says a state transition
/// arrives once, and this is what keeps that true on the one path where it
/// would not be.
///
/// The two guards look alike and are not: the removed one was over a value
/// that could not repeat, and this one is over an announcement that can.
class ResumableChunkObserver extends http.BaseClient {
  ResumableChunkObserver(this._inner, this._events);

  final http.Client _inner;
  final PlayUploadEvents _events;

  /// Whether the wait for the store's answer has already been named.
  var _announcedAccepting = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final range = request.method == 'PUT'
        ? _contentRange.firstMatch(request.headers['content-range'] ?? '')
        : null;
    if (range == null) {
      // Everything else this client carries: opening the session, the edit
      // calls around it, the token refresh underneath. Passed through
      // untouched, which is the point of observing rather than reimplementing.
      return _inner.send(request);
    }

    final sent = int.parse(range.group(2)!) + 1;
    final total = int.parse(range.group(3)!);

    // **Said before the request rather than after it, because the wait is
    // inside the request.** The final chunk is the one Play answers with the
    // `Bundle` it read out of the artifact, and it validates the artifact
    // before answering — so by the time this method has a response the wait a
    // reader wanted named is already over.
    //
    // Once, however many attempts the final chunk takes — see the class doc.
    if (sent == total && !_announcedAccepting) {
      _announcedAccepting = true;
      _events.state(UploadState.accepting);
    }

    final response = await _inner.send(request);

    // 308 is "I have that much, keep going"; 200 and 201 are the last chunk
    // accepted. Anything else is a failure the uploader will raise on, and a
    // progress line for a chunk that did not land would be the one kind of
    // lie this stream must not tell.
    const accepted = {200, 201, 308};
    if (accepted.contains(response.statusCode)) {
      _events.progress(bytesSent: sent, bytesTotal: total);
    }
    return response;
  }

  @override
  void close() => _inner.close();
}
