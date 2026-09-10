// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'documents.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

AppStoreBuildEntry _$AppStoreBuildEntryFromJson(Map<String, dynamic> json) =>
    AppStoreBuildEntry(
      buildNumber: json['buildNumber'] as String,
      buildNumberAsInt: (json['buildNumberAsInt'] as num?)?.toInt(),
      processingState: $enumDecodeNullable(
        _$ProcessingStateEnumMap,
        json['processingState'],
        unknownValue: ProcessingState.unknown,
      ),
      processingStateRaw: json['processingStateRaw'] as String?,
      uploadedDate: json['uploadedDate'] as String?,
      expired: json['expired'] as bool,
      usable: json['usable'] as bool,
      needsNewUpload: json['needsNewUpload'] as bool?,
      display: (json['display'] as List<dynamic>)
          .map((e) => e as String)
          .toList(),
    );

Map<String, dynamic> _$AppStoreBuildEntryToJson(AppStoreBuildEntry instance) =>
    <String, dynamic>{
      'buildNumber': instance.buildNumber,
      'buildNumberAsInt': instance.buildNumberAsInt,
      'processingState': _$ProcessingStateEnumMap[instance.processingState],
      'processingStateRaw': instance.processingStateRaw,
      'uploadedDate': instance.uploadedDate,
      'expired': instance.expired,
      'usable': instance.usable,
      'needsNewUpload': instance.needsNewUpload,
      'display': instance.display,
    };

const _$ProcessingStateEnumMap = {
  ProcessingState.processing: 'processing',
  ProcessingState.valid: 'valid',
  ProcessingState.failed: 'failed',
  ProcessingState.invalid: 'invalid',
  ProcessingState.unknown: 'unknown',
};

AppStoreBuildsDocument _$AppStoreBuildsDocumentFromJson(
  Map<String, dynamic> json,
) => AppStoreBuildsDocument(
  schema: (json['schema'] as num).toInt(),
  kind: $enumDecode(_$DocumentKindEnumMap, json['kind']),
  platform: _platformFromJson(json['platform'] as String),
  bundleId: json['bundleId'] as String,
  newestBuildNumber: json['newestBuildNumber'] as String?,
  newestBuildNumberAsInt: (json['newestBuildNumberAsInt'] as num?)?.toInt(),
  builds: (json['builds'] as List<dynamic>)
      .map((e) => AppStoreBuildEntry.fromJson(e as Map<String, dynamic>))
      .toList(),
  display: (json['display'] as List<dynamic>).map((e) => e as String).toList(),
);

Map<String, dynamic> _$AppStoreBuildsDocumentToJson(
  AppStoreBuildsDocument instance,
) => <String, dynamic>{
  'schema': instance.schema,
  'kind': _$DocumentKindEnumMap[instance.kind]!,
  'platform': _platformToJson(instance.platform),
  'bundleId': instance.bundleId,
  'newestBuildNumber': instance.newestBuildNumber,
  'newestBuildNumberAsInt': instance.newestBuildNumberAsInt,
  'builds': instance.builds.map((e) => e.toJson()).toList(),
  'display': instance.display,
};

const _$DocumentKindEnumMap = {
  DocumentKind.appStoreBuilds: 'appstore.builds',
  DocumentKind.appStoreVersions: 'appstore.versions',
  DocumentKind.appStorePreviews: 'appstore.previews',
  DocumentKind.playTracks: 'play.tracks',
  DocumentKind.appStoreListingDiff: 'appstore.listing-diff',
  DocumentKind.verify: 'verify',
};

AppStoreVersionEntry _$AppStoreVersionEntryFromJson(
  Map<String, dynamic> json,
) => AppStoreVersionEntry(
  versionString: json['versionString'] as String,
  appStoreState: $enumDecodeNullable(
    _$AppStoreStateEnumMap,
    json['appStoreState'],
    unknownValue: AppStoreState.unknown,
  ),
  appStoreStateRaw: json['appStoreStateRaw'] as String?,
  releaseType: $enumDecodeNullable(
    _$ReleaseTypeEnumMap,
    json['releaseType'],
    unknownValue: ReleaseType.unknown,
  ),
  releaseTypeRaw: json['releaseTypeRaw'] as String?,
  copyright: json['copyright'] as String?,
  editable: json['editable'] as bool,
  buildNumber: json['buildNumber'] as String?,
  buildNumberAsInt: (json['buildNumberAsInt'] as num?)?.toInt(),
  display: (json['display'] as List<dynamic>).map((e) => e as String).toList(),
);

Map<String, dynamic> _$AppStoreVersionEntryToJson(
  AppStoreVersionEntry instance,
) => <String, dynamic>{
  'versionString': instance.versionString,
  'appStoreState': _$AppStoreStateEnumMap[instance.appStoreState],
  'appStoreStateRaw': instance.appStoreStateRaw,
  'releaseType': _$ReleaseTypeEnumMap[instance.releaseType],
  'releaseTypeRaw': instance.releaseTypeRaw,
  'copyright': instance.copyright,
  'editable': instance.editable,
  'buildNumber': instance.buildNumber,
  'buildNumberAsInt': instance.buildNumberAsInt,
  'display': instance.display,
};

const _$AppStoreStateEnumMap = {
  AppStoreState.prepareForSubmission: 'prepareForSubmission',
  AppStoreState.readyForReview: 'readyForReview',
  AppStoreState.waitingForReview: 'waitingForReview',
  AppStoreState.inReview: 'inReview',
  AppStoreState.pendingAppleRelease: 'pendingAppleRelease',
  AppStoreState.processingForAppStore: 'processingForAppStore',
  AppStoreState.replacedWithNewVersion: 'replacedWithNewVersion',
  AppStoreState.accepted: 'accepted',
  AppStoreState.rejected: 'rejected',
  AppStoreState.developerRejected: 'developerRejected',
  AppStoreState.metadataRejected: 'metadataRejected',
  AppStoreState.invalidBinary: 'invalidBinary',
  AppStoreState.pendingDeveloperRelease: 'pendingDeveloperRelease',
  AppStoreState.preorderReadyForSale: 'preorderReadyForSale',
  AppStoreState.readyForSale: 'readyForSale',
  AppStoreState.developerRemovedFromSale: 'developerRemovedFromSale',
  AppStoreState.removedFromSale: 'removedFromSale',
  AppStoreState.unknown: 'unknown',
};

const _$ReleaseTypeEnumMap = {
  ReleaseType.manual: 'manual',
  ReleaseType.afterApproval: 'afterApproval',
  ReleaseType.scheduled: 'scheduled',
  ReleaseType.unknown: 'unknown',
};

AppStoreVersionsDocument _$AppStoreVersionsDocumentFromJson(
  Map<String, dynamic> json,
) => AppStoreVersionsDocument(
  schema: (json['schema'] as num).toInt(),
  kind: $enumDecode(_$DocumentKindEnumMap, json['kind']),
  platform: _platformFromJson(json['platform'] as String),
  bundleId: json['bundleId'] as String,
  versions: (json['versions'] as List<dynamic>)
      .map((e) => AppStoreVersionEntry.fromJson(e as Map<String, dynamic>))
      .toList(),
  display: (json['display'] as List<dynamic>).map((e) => e as String).toList(),
);

Map<String, dynamic> _$AppStoreVersionsDocumentToJson(
  AppStoreVersionsDocument instance,
) => <String, dynamic>{
  'schema': instance.schema,
  'kind': _$DocumentKindEnumMap[instance.kind]!,
  'platform': _platformToJson(instance.platform),
  'bundleId': instance.bundleId,
  'versions': instance.versions.map((e) => e.toJson()).toList(),
  'display': instance.display,
};

AppStorePreviewEntry _$AppStorePreviewEntryFromJson(
  Map<String, dynamic> json,
) => AppStorePreviewEntry(
  id: json['id'] as String?,
  locale: json['locale'] as String?,
  previewType: json['previewType'] as String?,
  fileName: json['fileName'] as String?,
  videoDeliveryState: json['videoDeliveryState'] as String?,
  previewFrameImageState: json['previewFrameImageState'] as String?,
  previewFrameTimeCode: json['previewFrameTimeCode'] as String?,
  done: json['done'] as bool,
);

Map<String, dynamic> _$AppStorePreviewEntryToJson(
  AppStorePreviewEntry instance,
) => <String, dynamic>{
  'id': instance.id,
  'locale': instance.locale,
  'previewType': instance.previewType,
  'fileName': instance.fileName,
  'videoDeliveryState': instance.videoDeliveryState,
  'previewFrameImageState': instance.previewFrameImageState,
  'previewFrameTimeCode': instance.previewFrameTimeCode,
  'done': instance.done,
};

AppStorePreviewsDocument _$AppStorePreviewsDocumentFromJson(
  Map<String, dynamic> json,
) => AppStorePreviewsDocument(
  schema: (json['schema'] as num).toInt(),
  kind: $enumDecode(_$DocumentKindEnumMap, json['kind']),
  platform: _platformFromJson(json['platform'] as String),
  bundleId: json['bundleId'] as String,
  versionName: json['versionName'] as String,
  previews: (json['previews'] as List<dynamic>)
      .map((e) => AppStorePreviewEntry.fromJson(e as Map<String, dynamic>))
      .toList(),
  display: (json['display'] as List<dynamic>).map((e) => e as String).toList(),
);

Map<String, dynamic> _$AppStorePreviewsDocumentToJson(
  AppStorePreviewsDocument instance,
) => <String, dynamic>{
  'schema': instance.schema,
  'kind': _$DocumentKindEnumMap[instance.kind]!,
  'platform': _platformToJson(instance.platform),
  'bundleId': instance.bundleId,
  'versionName': instance.versionName,
  'previews': instance.previews.map((e) => e.toJson()).toList(),
  'display': instance.display,
};

PlayReleaseEntry _$PlayReleaseEntryFromJson(Map<String, dynamic> json) =>
    PlayReleaseEntry(
      name: json['name'] as String?,
      status: $enumDecodeNullable(
        _$PlayReleaseStatusEnumMap,
        json['status'],
        unknownValue: PlayReleaseStatus.unknown,
      ),
      statusRaw: json['statusRaw'] as String?,
      versionCodes: (json['versionCodes'] as List<dynamic>)
          .map((e) => (e as num).toInt())
          .toList(),
      newestVersionCode: (json['newestVersionCode'] as num?)?.toInt(),
      serving: json['serving'] as bool?,
      userFraction: (json['userFraction'] as num?)?.toDouble(),
      audienceFraction: (json['audienceFraction'] as num?)?.toDouble(),
      display: (json['display'] as List<dynamic>)
          .map((e) => e as String)
          .toList(),
    );

Map<String, dynamic> _$PlayReleaseEntryToJson(PlayReleaseEntry instance) =>
    <String, dynamic>{
      'name': instance.name,
      'status': _$PlayReleaseStatusEnumMap[instance.status],
      'statusRaw': instance.statusRaw,
      'versionCodes': instance.versionCodes,
      'newestVersionCode': instance.newestVersionCode,
      'serving': instance.serving,
      'userFraction': instance.userFraction,
      'audienceFraction': instance.audienceFraction,
      'display': instance.display,
    };

const _$PlayReleaseStatusEnumMap = {
  PlayReleaseStatus.completed: 'completed',
  PlayReleaseStatus.inProgress: 'inProgress',
  PlayReleaseStatus.halted: 'halted',
  PlayReleaseStatus.draft: 'draft',
  PlayReleaseStatus.statusUnspecified: 'statusUnspecified',
  PlayReleaseStatus.unknown: 'unknown',
};

PlayTrackEntry _$PlayTrackEntryFromJson(Map<String, dynamic> json) =>
    PlayTrackEntry(
      name: json['name'] as String,
      newestVersionCode: (json['newestVersionCode'] as num?)?.toInt(),
      releases: (json['releases'] as List<dynamic>)
          .map((e) => PlayReleaseEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
      display: (json['display'] as List<dynamic>)
          .map((e) => e as String)
          .toList(),
    );

Map<String, dynamic> _$PlayTrackEntryToJson(PlayTrackEntry instance) =>
    <String, dynamic>{
      'name': instance.name,
      'newestVersionCode': instance.newestVersionCode,
      'releases': instance.releases.map((e) => e.toJson()).toList(),
      'display': instance.display,
    };

PlayTracksDocument _$PlayTracksDocumentFromJson(Map<String, dynamic> json) =>
    PlayTracksDocument(
      schema: (json['schema'] as num).toInt(),
      kind: $enumDecode(_$DocumentKindEnumMap, json['kind']),
      packageName: json['packageName'] as String,
      tracks: (json['tracks'] as List<dynamic>)
          .map((e) => PlayTrackEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
      uploadedVersionCodes: (json['uploadedVersionCodes'] as List<dynamic>)
          .map((e) => (e as num).toInt())
          .toList(),
      display: (json['display'] as List<dynamic>)
          .map((e) => e as String)
          .toList(),
    );

Map<String, dynamic> _$PlayTracksDocumentToJson(PlayTracksDocument instance) =>
    <String, dynamic>{
      'schema': instance.schema,
      'kind': _$DocumentKindEnumMap[instance.kind]!,
      'packageName': instance.packageName,
      'tracks': instance.tracks.map((e) => e.toJson()).toList(),
      'uploadedVersionCodes': instance.uploadedVersionCodes,
      'display': instance.display,
    };

VerifyCheck _$VerifyCheckFromJson(Map<String, dynamic> json) => VerifyCheck(
  what: json['what'] as String,
  where: json['where'] as String?,
  why: json['why'] as String?,
);

Map<String, dynamic> _$VerifyCheckToJson(VerifyCheck instance) =>
    <String, dynamic>{
      'what': instance.what,
      'where': instance.where,
      'why': instance.why,
    };

VerifyDocument _$VerifyDocumentFromJson(Map<String, dynamic> json) =>
    VerifyDocument(
      schema: (json['schema'] as num).toInt(),
      kind: $enumDecode(_$DocumentKindEnumMap, json['kind']),
      ok: json['ok'] as bool,
      checked: (json['checked'] as List<dynamic>)
          .map((e) => VerifyCheck.fromJson(e as Map<String, dynamic>))
          .toList(),
      skipped: (json['skipped'] as List<dynamic>)
          .map((e) => VerifyCheck.fromJson(e as Map<String, dynamic>))
          .toList(),
      problems: (json['problems'] as List<dynamic>)
          .map((e) => e as String)
          .toList(),
      display: (json['display'] as List<dynamic>)
          .map((e) => e as String)
          .toList(),
    );

Map<String, dynamic> _$VerifyDocumentToJson(VerifyDocument instance) =>
    <String, dynamic>{
      'schema': instance.schema,
      'kind': _$DocumentKindEnumMap[instance.kind]!,
      'ok': instance.ok,
      'checked': instance.checked.map((e) => e.toJson()).toList(),
      'skipped': instance.skipped.map((e) => e.toJson()).toList(),
      'problems': instance.problems,
      'display': instance.display,
    };

ListingChangeSet _$ListingChangeSetFromJson(Map<String, dynamic> json) =>
    ListingChangeSet(
      fields: (json['fields'] as List<dynamic>)
          .map((e) => e as String)
          .toList(),
      localizations: (json['localizations'] as Map<String, dynamic>).map(
        (k, e) =>
            MapEntry(k, (e as List<dynamic>).map((e) => e as String).toList()),
      ),
    );

Map<String, dynamic> _$ListingChangeSetToJson(ListingChangeSet instance) =>
    <String, dynamic>{
      'fields': instance.fields,
      'localizations': instance.localizations,
    };

AppStoreListingDiffDocument _$AppStoreListingDiffDocumentFromJson(
  Map<String, dynamic> json,
) => AppStoreListingDiffDocument(
  schema: (json['schema'] as num).toInt(),
  kind: $enumDecode(_$DocumentKindEnumMap, json['kind']),
  platform: _platformFromJson(json['platform'] as String),
  bundleId: json['bundleId'] as String,
  versionName: json['versionName'] as String?,
  matches: json['matches'] as bool,
  version: ListingChangeSet.fromJson(json['version'] as Map<String, dynamic>),
  app: ListingChangeSet.fromJson(json['app'] as Map<String, dynamic>),
  assets: (json['assets'] as List<dynamic>).map((e) => e as String).toList(),
  appleOnlyLocales: (json['appleOnlyLocales'] as List<dynamic>)
      .map((e) => e as String)
      .toList(),
  display: (json['display'] as List<dynamic>).map((e) => e as String).toList(),
);

Map<String, dynamic> _$AppStoreListingDiffDocumentToJson(
  AppStoreListingDiffDocument instance,
) => <String, dynamic>{
  'schema': instance.schema,
  'kind': _$DocumentKindEnumMap[instance.kind]!,
  'platform': _platformToJson(instance.platform),
  'bundleId': instance.bundleId,
  'versionName': instance.versionName,
  'matches': instance.matches,
  'version': instance.version.toJson(),
  'app': instance.app.toJson(),
  'assets': instance.assets,
  'appleOnlyLocales': instance.appleOnlyLocales,
  'display': instance.display,
};
