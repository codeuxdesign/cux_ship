// SPDX-License-Identifier: Apache-2.0
//
// App Store creative assets — the product page header and the search results
// image — published through the App Asset Library.
//
//   cux_ship appstore creative-assets [--version-name 1.2.0] [--dry-run]
//     [--submit-for-review]
//
// **Not a screenshot set with different sizes, and the differences are the
// design.** Read off Apple's OpenAPI specification, version 4.5.1, and the
// asset-library articles that came with it (docs/design/creative-assets.md has
// the sources and which parts are confirmed):
//
//   - **The bytes belong to the app, not the version.** Each app has one
//     `appAssetLibraries` resource, and an image is reserved into it. Nothing
//     about a version or a locale is said at upload.
//   - **Where it shows is a second resource.** An `appAssetLibraryPlacements`
//     row joins one image to one `appStoreVersionLocalization` as one
//     placement type — `PRODUCT_PAGE_HEADER_ASSET` or
//     `APP_STORE_SEARCH_RESULTS_ASSET`. Placements cannot be edited, only
//     deleted and made again, and only while the version is editable.
//   - **Apple keeps no checksum.** The commit is `uploaded: true` alone, and the
//     image reads back with no `sourceFileChecksum`. So "these bytes are
//     already there" is answered by a checksum this package writes into the
//     image's `referenceName` — its own convention, which Apple's migration
//     guide invites ("record the returned asset ID against your own
//     identifier") without prescribing.
//   - **An image has its own review state**, separate from any version's, and
//     can be submitted for review on its own. This package never does that
//     unless `--submit-for-review` says so.
import 'dart:io';

import 'package:cux_ship_verify/metadata.dart';

import 'app_store.dart';
import 'asc_client.dart';

/// `AppAssetLibraryAssetCategory` for these assets. It cannot be changed after
/// reservation, so it is sent on every reservation rather than defaulted.
const creativeAssetCategory = 'CREATIVE_ASSETS';

/// The states an image passes through while Apple still has the bytes in hand.
const processingLibraryStates = {'AWAITING_UPLOAD', 'UPLOAD_COMPLETE'};

/// The states in which an image is usable — processed, and not refused.
///
/// Ordered from furthest along to least, which is the order a reuse prefers:
/// if the same bytes were uploaded twice and one copy is already approved, that
/// is the one to place. `COMPLETE` is last because Apple's specification maps
/// it and none of its articles describes it.
const usableLibraryStates = [
  'APPROVED',
  'ACCEPTED',
  'IN_REVIEW',
  'WAITING_FOR_REVIEW',
  'READY_FOR_REVIEW',
  'PREPARE_FOR_SUBMISSION',
  'COMPLETE',
];

/// The usable states that have not been sent to App Review yet — the only ones
/// `--submit-for-review` adds to a submission.
const submittableLibraryStates = {'PREPARE_FOR_SUBMISSION', 'COMPLETE'};

final _checksumMarker = RegExp(r' \[md5 ([0-9a-f]{32})\]$');

/// The `referenceName` an uploaded creative asset is given.
///
/// **The file name for a person, the checksum for the next run.** The
/// reference name is what App Store Connect shows in the asset library, so it
/// starts with something recognisable; the bracketed MD5 is what
/// [checksumFromReferenceName] reads back. MD5 because it is [checksumOf], the
/// digest the screenshot skip already compares — one digest function across
/// both skips, so the two can never disagree about what "unchanged" means.
String creativeReferenceName(String fileName, String checksum) =>
    '$fileName [md5 $checksum]';

/// The checksum [creativeReferenceName] wrote, or null for a name it did not
/// write — an asset uploaded in the console, or one somebody renamed there.
///
/// Null is a mismatch, never a match, which costs an upload nobody needed
/// rather than a placement of bytes nobody checked.
String? checksumFromReferenceName(String? referenceName) =>
    referenceName == null
    ? null
    : _checksumMarker.firstMatch(referenceName)?.group(1);

/// One `appAssetLibraryImages` resource, reduced to what this package reads.
typedef LibraryImage = ({
  String id,
  String? fileName,
  String? referenceName,
  String? state,
  String? specId,
  List<String> stateDetails,
});

/// [resource] as a [LibraryImage], or null when it carries no id.
LibraryImage? readLibraryImage(Map<String, dynamic> resource) {
  final id = resource['id'];
  if (id is! String) {
    return null;
  }
  final attributes = resource['attributes'];
  final a = attributes is Map<String, dynamic>
      ? attributes
      : const <String, dynamic>{};
  final details = a['stateDetails'];
  return (
    id: id,
    fileName: a['fileName'] as String?,
    referenceName: a['referenceName'] as String?,
    state: a['state'] as String?,
    specId: a['specId'] as String?,
    stateDetails: [
      if (details is List)
        for (final detail in details.whereType<Map<String, dynamic>>())
          [
            detail['code'],
            detail['description'],
          ].whereType<String>().join(' - '),
    ].where((line) => line.isNotEmpty).toList(),
  );
}

/// What to do about one file, given what the library already holds.
sealed class LibraryMatch {
  const LibraryMatch();
}

/// The same bytes are in the library and usable.
final class ReuseImage extends LibraryMatch {
  const ReuseImage(this.image);
  final LibraryImage image;
}

/// The same bytes are in the library and Apple is still processing them —
/// wait rather than upload a second copy.
final class AwaitImage extends LibraryMatch {
  const AwaitImage(this.image);
  final LibraryImage image;
}

/// App Review refused these exact bytes. Uploading them again would be
/// refused again, so the run stops and says so.
final class RejectedImage extends LibraryMatch {
  const RejectedImage(this.image);
  final LibraryImage image;
}

/// Upload the file, after deleting [stale] copies of the same bytes that can
/// never become usable: a reservation an interrupted run never committed
/// (`AWAITING_UPLOAD`), or one Apple refused during processing (`FAILED`),
/// which Apple's guidance is to delete and reserve again.
final class UploadImage extends LibraryMatch {
  const UploadImage([this.stale = const []]);
  final List<LibraryImage> stale;
}

/// Decides what to do about bytes whose MD5 is [checksum].
///
/// Pure, so every branch is reachable from a literal. An `ARCHIVED` copy is
/// ignored, because archiving is somebody's decision to retire it.
LibraryMatch matchInLibrary(List<LibraryImage> library, String checksum) {
  final same = library
      .where(
        (image) => checksumFromReferenceName(image.referenceName) == checksum,
      )
      .toList();
  for (final state in usableLibraryStates) {
    final usable = same.where((image) => image.state == state);
    if (usable.isNotEmpty) {
      return ReuseImage(usable.first);
    }
  }
  final processing = same.where((i) => i.state == 'UPLOAD_COMPLETE');
  if (processing.isNotEmpty) {
    return AwaitImage(processing.first);
  }
  final rejected = same.where((i) => i.state == 'REJECTED');
  if (rejected.isNotEmpty) {
    return RejectedImage(rejected.first);
  }
  return UploadImage([
    for (final image in same)
      if (image.state == 'AWAITING_UPLOAD' || image.state == 'FAILED') image,
  ]);
}

/// What one placement type in one placement group on one localization needs.
///
/// [keep] is the placement already joining the wanted image, if any; [delete]
/// is every other placement of the type in the group, which has to go first
/// because a version takes one header per group. [create] is true when nothing
/// joins the wanted image yet.
typedef PlacementPlan = ({String? keep, List<String> delete, bool create});

/// Plans one placement type, from two server-side filtered listings: every
/// placement of the type ([existing]) and those of the type joining the
/// wanted image ([joining]).
///
/// **Two filtered reads rather than one read and a look at the
/// relationships**, because whether a placement's `relationships.image`
/// carries `data` without an `include` is unmeasured — the same question
/// `appStoreVersions` answered "no" to for its build. A filter is answered by
/// Apple whatever the response shape.
PlacementPlan planPlacement({
  required List<String> existing,
  required List<String> joining,
}) {
  final keep = joining.isEmpty ? null : joining.first;
  return (
    keep: keep,
    delete: [
      for (final id in existing)
        if (id != keep) id,
    ],
    create: keep == null,
  );
}

/// The `AppAssetLibraryPlacementPlatform` values an iOS app's version is shown
/// on. Creative assets are iOS and iPadOS only (App Store Connect Help,
/// *Manage your App Store assets*).
const iosPlacementPlatforms = {'IPHONE_APP_STORE', 'IPAD_APP_STORE', 'ANY'};

/// The placement groups [placementType] takes a file of [specId] in, among
/// those on [platforms], read from the asset library's reference data.
///
/// **Apple's documented route, followed rather than shortcut.** A placement
/// names a placement group, the group identifiers come from the reference data
/// and "aren't an enumeration", and Apple asks callers not to hard-code them
/// (*Placing assets on your App Store surfaces*, *Discovering asset
/// specifications*). Apple matches an uploaded file to a specification during
/// processing and reports it as `specId`; `placementTypes[].specMappings` maps
/// each group to the specifications it accepts. So the groups an image belongs
/// in are the ones whose mapping lists its `specId`.
///
/// **Every such group, not the first.** "1 product page header asset per
/// group" means a header is placed once per group — an iPhone group and an
/// iPad group are two placements of one image, and placing only one would
/// leave the other device without a header with nothing said.
///
/// A group whose platform the reference data does not give is left out, on
/// the same reasoning as [platforms]: placing on a surface nobody can name is
/// a guess, and Apple's guidance for an unrecognized identifier is to refresh,
/// not to use it.
List<String> placementGroupsFor(
  Map<String, dynamic> referenceData, {
  required String placementType,
  required String specId,
  Set<String> platforms = iosPlacementPlatforms,
}) {
  final platformOf = <String, String>{
    for (final group in _maps(referenceData['placementProfileGroups']))
      if (group case {
        'placementProfileGroupId': final String id,
        'platform': final String platform,
      })
        id: platform,
  };
  return [
    for (final type in _maps(referenceData['placementTypes']))
      if (type['placementTypeId'] == placementType)
        for (final mapping in _maps(type['specMappings']))
          if (mapping case {
            'placementGroupId': final String group,
            'specs': final List<Object?> specs,
          })
            if (specs.contains(specId) && platforms.contains(platformOf[group]))
              group,
  ];
}

Iterable<Map<String, dynamic>> _maps(Object? list) =>
    list is List ? list.whereType<Map<String, dynamic>>() : const [];

/// Raised when the run refuses to go on, for a reason that is this package's
/// rather than Apple's.
class CreativeAssetsRefused implements Exception {
  CreativeAssetsRefused(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One creative-asset file in one locale, and what the run did with it.
class CreativeAssetOutcome {
  CreativeAssetOutcome({
    required this.locale,
    required this.slot,
    required this.file,
    required this.checksum,
  });

  final String locale;
  final String slot;
  final File file;
  final String checksum;

  /// The library image these bytes are, or null on a dry run that would
  /// upload them.
  String? imageId;

  /// `uploaded`, `unchanged`, or `would upload`.
  String library = '';

  /// `<placement type> <group>` -> `placed`, `unchanged` or `would place`; or
  /// a bare placement type -> `not placed` / `would place` when no group was
  /// resolved, because nothing was placed or the image is not processed yet.
  final Map<String, String> placements = {};

  /// The image's state as last read, after any submission.
  String? state;

  String get fileName => file.uri.pathSegments.last;
}

/// Uploads, places and optionally submits a tree's creative assets.
class CreativeAssetPublisher {
  CreativeAssetPublisher(
    this.client,
    this.writer, {
    required this.platform,
    required this.say,
    this.timeout = const Duration(minutes: 10),
    this.poll = const Duration(seconds: 5),
  });

  final AscClient client;
  final Writer writer;
  final AscPlatform platform;
  final void Function(String line) say;
  final Duration timeout;
  final Duration poll;

  /// The `reviewSubmissions` container [submitForReview] created, if it
  /// created one — so a run that fails after making it can still say so, the
  /// way [AppStore.createdReviewSubmission] does for a version.
  String? createdReviewSubmission;

  /// The app's one asset library.
  Future<String> assetLibraryId(App app) async {
    final response = await client.get('/v1/apps/${app.id}/assetLibrary');
    final data = response['data'];
    final id = data is Map<String, dynamic> ? data['id'] : null;
    if (id is! String) {
      throw AscApiException(404, [
        'App Store Connect returned no asset library for ${app.name}.',
      ], request: 'GET /v1/apps/{id}/assetLibrary');
    }
    return id;
  }

  /// Every creative-asset image in the library.
  ///
  /// Filtered to the category server-side, because the library also holds
  /// screenshots and previews under the asset library's other category.
  Future<List<LibraryImage>> libraryImages(String libraryId) async => [
    for (final resource in await client.getAll(
      '/v1/appAssetLibraries/$libraryId/images',
      query: {'filter[category]': creativeAssetCategory},
    ))
      ?readLibraryImage(resource),
  ];

  /// Makes sure the library holds every file in [outcomes], uploading what it
  /// does not, and waits until Apple has processed them.
  ///
  /// The same bytes in two locales are one image placed twice — the asset
  /// library exists so they need not be uploaded twice.
  Future<void> ensureInLibrary(
    String libraryId,
    List<CreativeAssetOutcome> outcomes,
  ) async {
    final library = await libraryImages(libraryId);
    final byChecksum = <String, ({String? id, String library})>{};
    final waitFor = <String>{};

    for (final outcome in outcomes) {
      final done = byChecksum[outcome.checksum];
      if (done != null) {
        outcome
          ..imageId = done.id
          ..library = done.library;
        continue;
      }
      final String? id;
      final String verdict;
      switch (matchInLibrary(library, outcome.checksum)) {
        case ReuseImage(:final image):
          say(
            '    ${outcome.locale} ${outcome.slot}: ${outcome.fileName} is '
            'already in the asset library (${image.state}), unchanged',
          );
          id = image.id;
          verdict = 'unchanged';
        case AwaitImage(:final image):
          say(
            '    ${outcome.locale} ${outcome.slot}: ${outcome.fileName} is '
            'already uploaded and Apple is still processing it',
          );
          id = image.id;
          verdict = 'unchanged';
          waitFor.add(image.id);
        case RejectedImage(:final image):
          throw CreativeAssetsRefused(
            '${outcome.locale} ${outcome.slot}: App Review rejected these exact '
            'bytes (${outcome.fileName}, asset ${image.id}). Uploading them '
            'again would be rejected again — change the image, or appeal in '
            'App Store Connect.',
          );
        case UploadImage(:final stale):
          for (final image in stale) {
            await writer.delete(
              '/v1/appAssetLibraryImages/${image.id}',
              describe:
                  'deleted an earlier ${image.state} copy of '
                  '${outcome.fileName} (${image.id})',
            );
          }
          id = await _upload(libraryId, outcome);
          verdict = writer.dryRun ? 'would upload' : 'uploaded';
          if (id != null) {
            waitFor.add(id);
          }
      }
      outcome
        ..imageId = id
        ..library = verdict;
      byChecksum[outcome.checksum] = (id: id, library: verdict);
    }

    await awaitProcessing(waitFor.toList());
  }

  /// Apple's asset upload: reserve, PUT the parts, commit with `uploaded`.
  ///
  /// **No checksum in the commit.** Apple's asset library guide says so in as
  /// many words — "there's no `sourceFileChecksum` attribute to send" — and
  /// validates the transfer against the declared `fileSize` instead.
  Future<String?> _upload(
    String libraryId,
    CreativeAssetOutcome outcome,
  ) async {
    final bytes = outcome.file.readAsBytesSync();
    final sentReferenceName = creativeReferenceName(
      outcome.fileName,
      outcome.checksum,
    );
    final reserved = await writer.post('/v1/appAssetLibraryImages', {
      'data': {
        'type': 'appAssetLibraryImages',
        'attributes': {
          'category': creativeAssetCategory,
          'fileName': outcome.fileName,
          'fileSize': bytes.length,
          'referenceName': sentReferenceName,
        },
        'relationships': {
          'assetLibrary': relation('appAssetLibraries', libraryId),
        },
      },
    }, describe: '${outcome.locale} ${outcome.slot}: ${outcome.fileName}');

    final data = reserved?['data'];
    if (data is! Map<String, dynamic>) {
      // A dry run, which reserves nothing and so has nothing to send.
      return null;
    }
    final id = data['id'];
    final attributes = data['attributes'];
    final operations = attributes is Map<String, dynamic>
        ? attributes['uploadOperations']
        : null;
    if (id is! String || operations is! List) {
      throw StateError(
        'reserving ${outcome.fileName} returned no id or uploadOperations',
      );
    }
    // **The marker has to read back as written, or the skip is gone.** Apple
    // publishes no length or character rule for `referenceName`; a truncated
    // or normalised echo means the next run finds no checksum, uploads again,
    // and reports "uploaded" every time — a re-upload forever that nothing
    // else would name. The reservation is kept either way: the bytes are
    // right, and only the next run's shortcut is lost.
    final stored = attributes is Map<String, dynamic>
        ? attributes['referenceName']
        : null;
    if (stored != sentReferenceName) {
      say(
        '    warning: App Store Connect stored the reference name of '
        '${outcome.fileName} as ${stored is String ? '"$stored"' : 'nothing'} '
        'rather than "$sentReferenceName", so the next run will not '
        'recognise these bytes and will upload them again',
      );
    }
    for (final operation in operations.whereType<Map<String, dynamic>>()) {
      final offset = operation['offset'];
      final length = operation['length'];
      if (offset is! int || length is! int) {
        throw StateError(
          'upload operation for ${outcome.fileName} has no offset/length',
        );
      }
      await client.uploadOperation(
        operation,
        bytes.sublist(offset, offset + length),
      );
    }
    await writer.patch('/v1/appAssetLibraryImages/$id', {
      'data': {
        'type': 'appAssetLibraryImages',
        'id': id,
        'attributes': {'uploaded': true},
      },
    }, describe: 'committed ${outcome.fileName}');
    return id;
  }

  /// Waits until Apple has finished processing [imageIds], or says why it
  /// will not.
  ///
  /// `FAILED` is where a wrong size lands — Apple matches the file against a
  /// specification during processing — and its `stateDetails` are Apple's own
  /// words, so they are what the error carries.
  Future<void> awaitProcessing(List<String> imageIds) async {
    if (imageIds.isEmpty || writer.dryRun) {
      return;
    }
    final deadline = DateTime.now().add(timeout);
    final pending = [...imageIds];
    var announced = false;
    while (true) {
      final still = <String>[];
      for (final id in pending) {
        final image = await readImage(id);
        if (image == null || processingLibraryStates.contains(image.state)) {
          still.add(id);
          continue;
        }
        if (image.state == 'FAILED') {
          throw AscApiException(422, [
            'Apple could not process the creative asset '
                '${image.fileName ?? id}.',
            ...image.stateDetails,
            if (image.stateDetails.isEmpty)
              'It gave no reason. A size or format the specification does not '
                  'take is the usual one, and `cux_ship verify` checks both.',
          ], request: 'GET /v1/appAssetLibraryImages');
        }
      }
      if (still.isEmpty) {
        return;
      }
      if (DateTime.now().isAfter(deadline)) {
        throw AscApiException(504, [
          'Apple has not finished processing ${still.length} creative '
              'asset(s) after ${timeout.inMinutes} minutes.',
          'They are uploaded. Re-running finds them by checksum and waits '
              'again rather than uploading them twice.',
        ], request: 'GET /v1/appAssetLibraryImages');
      }
      if (!announced) {
        say('      waiting for Apple to process ${still.length} image(s)');
        announced = true;
      }
      pending
        ..clear()
        ..addAll(still);
      await Future<void>.delayed(poll);
    }
  }

  /// One image as Apple reports it now, or null when the response carried
  /// none.
  Future<LibraryImage?> readImage(String id) async {
    final response = await client.get('/v1/appAssetLibraryImages/$id');
    final data = response['data'];
    return data is Map<String, dynamic> ? readLibraryImage(data) : null;
  }

  /// The attributes of the asset library's reference data: the catalog of
  /// specifications, placement types and placement groups.
  ///
  /// Read whole rather than through `filter[placementTypes]`, because how that
  /// filter narrows the *other* arrays — the placement groups the mapping
  /// names — is not documented, and the groups are what is needed.
  Future<Map<String, dynamic>> referenceData() async {
    final collection = await client.getAll('/v1/appAssetLibraryRefData');
    final attributes = collection.isEmpty
        ? null
        : collection.first['attributes'];
    if (attributes is! Map<String, dynamic>) {
      throw AscApiException(404, [
        'App Store Connect returned no asset library reference data, which '
            'is where placement groups come from.',
      ], request: 'GET /v1/appAssetLibraryRefData');
    }
    return attributes;
  }

  /// Joins [imageId] to [localizationId] as [placementType] in
  /// [placementGroup], replacing any other image placed there.
  Future<String> place({
    required String locale,
    required String localizationId,
    required String placementType,
    required String placementGroup,
    required String imageId,
  }) async {
    final path = '/v1/appStoreVersionLocalizations/$localizationId/placements';
    final slot = {
      'filter[placementType]': placementType,
      'filter[placementGroup]': placementGroup,
    };
    final existing = await client.getAll(path, query: slot);
    final joining = await client.getAll(
      path,
      query: {...slot, 'filter[image]': imageId},
    );
    final plan = planPlacement(
      existing: [for (final p in existing) ?p['id'] as String?],
      joining: [for (final p in joining) ?p['id'] as String?],
    );

    final where = '$locale $placementType $placementGroup';
    if (plan.keep != null && plan.delete.isEmpty) {
      say('    $where: already placed, unchanged');
      return 'unchanged';
    }
    // **Deleted before the new one is made**, because a version takes one
    // header per group and a second would be refused. A run that dies between
    // the two leaves the slot empty until the next run, which recreates it.
    for (final id in plan.delete) {
      await writer.delete(
        '/v1/appAssetLibraryPlacements/$id',
        describe: 'removed the earlier $where placement',
      );
    }
    if (!plan.create) {
      return 'placed';
    }
    final created = await writer.post('/v1/appAssetLibraryPlacements', {
      'data': {
        'type': 'appAssetLibraryPlacements',
        'attributes': {
          'placementType': placementType,
          'placementGroup': placementGroup,
        },
        'relationships': {
          'image': relation('appAssetLibraryImages', imageId),
          'appStoreVersionLocalization': relation(
            'appStoreVersionLocalizations',
            localizationId,
          ),
        },
      },
    }, describe: 'placed as the $where');
    return created == null ? 'would place' : 'placed';
  }

  /// Submits [imageIds] to App Review on their own, independent of a version.
  ///
  /// **Only ever called behind `--submit-for-review`.** The container, item
  /// and `submitted` flip are the same three steps a version submission takes
  /// ([AppStore.submitForReview]); what is new is the item's relationship,
  /// `appAssetLibraryImage`, which Apple's 4.5.1 specification adds to
  /// `reviewSubmissionItems`. No Apple article walks through this sequence for
  /// an asset, which is said in the design document rather than left implied.
  ///
  /// **An open container is reused only while it is empty.** One that already
  /// holds a version, an event or anything else would be submitted with the
  /// assets when `submitted` flips, and a flag asking to submit *assets* is not
  /// a request to submit those.
  ///
  /// [awaitingUpload] is how many distinct files a dry run would have uploaded
  /// and so could not read a state for. Without it a dry run of
  /// `--submit-for-review` over new bytes said "no creative asset is waiting
  /// to be submitted" — the sentence for the opposite outcome, on the run
  /// whose whole purpose is to say what the real one would do.
  Future<void> submitForReview(
    App app,
    List<LibraryImage> images, {
    int awaitingUpload = 0,
  }) async {
    final wanted = [
      for (final image in images)
        if (submittableLibraryStates.contains(image.state)) image,
    ];
    for (final image in images) {
      if (!submittableLibraryStates.contains(image.state)) {
        say(
          '    ${image.fileName ?? image.id} is ${image.state ?? 'in no '
                  'reported state'}; not added to a submission',
        );
      }
    }
    if (wanted.isEmpty && awaitingUpload == 0) {
      say('==> no creative asset is waiting to be submitted');
      return;
    }
    if (wanted.isEmpty) {
      say(
        '==> would submit the $awaitingUpload creative asset(s) this run would '
        'upload, once Apple has processed them',
      );
      return;
    }

    final open = await client.getAll(
      '/v1/reviewSubmissions',
      query: {
        'filter[app]': app.id,
        'filter[platform]': platform.api,
        'filter[state]': 'READY_FOR_REVIEW',
      },
    );
    String? submissionId;
    if (open.isNotEmpty) {
      final candidate = open.first['id'] as String?;
      final items = await client.getAll(
        '/v1/reviewSubmissions/$candidate/items',
      );
      if (items.isNotEmpty) {
        throw CreativeAssetsRefused(
          'an unsubmitted review submission ($candidate) already holds '
          '${items.length} item(s), and submitting the creative assets would '
          'submit those with them. Submit or remove them in App Store Connect '
          'first, then run this again.',
        );
      }
      submissionId = candidate;
      say('==> reusing the empty open review submission $submissionId');
    } else {
      final created = await writer.post('/v1/reviewSubmissions', {
        'data': {
          'type': 'reviewSubmissions',
          'attributes': {'platform': platform.api},
          'relationships': {'app': relation('apps', app.id)},
        },
      }, describe: 'review submission');
      final data = created?['data'];
      submissionId = data is Map<String, dynamic>
          ? data['id'] as String?
          : null;
      createdReviewSubmission = submissionId;
    }

    if (submissionId == null) {
      say(
        '    would then add ${wanted.length + awaitingUpload} creative '
        'asset(s) and submit them for review',
      );
      return;
    }
    for (final image in wanted) {
      await writer.post('/v1/reviewSubmissionItems', {
        'data': {
          'type': 'reviewSubmissionItems',
          'relationships': {
            'reviewSubmission': relation('reviewSubmissions', submissionId),
            'appAssetLibraryImage': relation('appAssetLibraryImages', image.id),
          },
        },
      }, describe: 'added ${image.fileName ?? image.id} to the submission');
    }
    await writer.patch('/v1/reviewSubmissions/$submissionId', {
      'data': {
        'type': 'reviewSubmissions',
        'id': submissionId,
        'attributes': {'submitted': true},
      },
    }, describe: 'submitted ${wanted.length} creative asset(s) for review');
  }
}

/// The files [metadata] asks to publish, one per locale and slot.
List<CreativeAssetOutcome> creativeAssetsIn(AppStoreMetadata metadata) => [
  for (final locale in metadata.locales)
    for (final entry in locale.creativeAssets.entries)
      CreativeAssetOutcome(
        locale: locale.locale,
        slot: entry.key,
        file: entry.value,
        checksum: checksumOf(entry.value.readAsBytesSync()),
      ),
];

/// The report a run ends with: one line per file, naming the library image,
/// its review state and each placement.
List<String> describeCreativeAssets(List<CreativeAssetOutcome> outcomes) => [
  for (final o in outcomes)
    '  ${o.locale}  ${o.slot}  ${o.fileName}  '
        '${o.library}${o.imageId == null ? '' : ' as ${o.imageId}'}  '
        'state ${o.state ?? '-'}'
        '${o.placements.entries.map((p) => '  ${p.key} ${p.value}').join()}',
];
