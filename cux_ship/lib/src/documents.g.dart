// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'documents.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

AppStoreBuildEntry _$AppStoreBuildEntryFromJson(Map<String, dynamic> json) =>
    AppStoreBuildEntry(
      buildNumber: json['buildNumber'] as String,
      buildNumberAsInt: (json['buildNumberAsInt'] as num?)?.toInt(),
      processingState: json['processingState'] as String?,
      uploadedDate: json['uploadedDate'] as String?,
      expired: json['expired'] as bool,
      usable: json['usable'] as bool,
      mayBecomeUsable: json['mayBecomeUsable'] as bool?,
      display: (json['display'] as List<dynamic>)
          .map((e) => e as String)
          .toList(),
    );

Map<String, dynamic> _$AppStoreBuildEntryToJson(AppStoreBuildEntry instance) =>
    <String, dynamic>{
      'buildNumber': instance.buildNumber,
      'buildNumberAsInt': instance.buildNumberAsInt,
      'processingState': instance.processingState,
      'uploadedDate': instance.uploadedDate,
      'expired': instance.expired,
      'usable': instance.usable,
      'mayBecomeUsable': instance.mayBecomeUsable,
      'display': instance.display,
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
  DocumentKind.playTracks: 'play.tracks',
};

AppStoreVersionEntry _$AppStoreVersionEntryFromJson(
  Map<String, dynamic> json,
) => AppStoreVersionEntry(
  versionString: json['versionString'] as String,
  appStoreState: json['appStoreState'] as String?,
  releaseType: json['releaseType'] as String?,
  copyright: json['copyright'] as String?,
  editable: json['editable'] as bool,
  display: (json['display'] as List<dynamic>).map((e) => e as String).toList(),
);

Map<String, dynamic> _$AppStoreVersionEntryToJson(
  AppStoreVersionEntry instance,
) => <String, dynamic>{
  'versionString': instance.versionString,
  'appStoreState': instance.appStoreState,
  'releaseType': instance.releaseType,
  'copyright': instance.copyright,
  'editable': instance.editable,
  'display': instance.display,
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

PlayReleaseEntry _$PlayReleaseEntryFromJson(Map<String, dynamic> json) =>
    PlayReleaseEntry(
      name: json['name'] as String?,
      status: json['status'] as String?,
      versionCodes: (json['versionCodes'] as List<dynamic>)
          .map((e) => (e as num).toInt())
          .toList(),
      newestVersionCode: (json['newestVersionCode'] as num?)?.toInt(),
      serving: json['serving'] as bool?,
      display: (json['display'] as List<dynamic>)
          .map((e) => e as String)
          .toList(),
    );

Map<String, dynamic> _$PlayReleaseEntryToJson(PlayReleaseEntry instance) =>
    <String, dynamic>{
      'name': instance.name,
      'status': instance.status,
      'versionCodes': instance.versionCodes,
      'newestVersionCode': instance.newestVersionCode,
      'serving': instance.serving,
      'display': instance.display,
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
