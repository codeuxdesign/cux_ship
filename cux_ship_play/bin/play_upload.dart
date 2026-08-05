// Uploads a signed .aab to a Google Play track.
//
//   dart run play_upload --aab dist/android/x.aab --package design.codeux.holdthewheel \
//     --build-number 12 --version-name 1.0.0 --track internal [--dry-run]
//
// Invoked by tool/upload.sh, which has already checked the manifest, the
// artifact digest and the provenance rules. This program does the API work and
// nothing else — everything it needs arrives as an argument or, for the service
// account, as an environment variable. It knows nothing about SOPS or manifests.
//
// The Play edit is a transaction: open one, attach a bundle, point a track at
// it, commit. Nothing is visible to anyone until the commit, which is what
// makes --dry-run genuinely safe — it does every step and then deletes the edit
// instead of committing it.
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:googleapis/androidpublisher/v3.dart';
import 'package:googleapis_auth/auth_io.dart';

const _serviceAccountVar = 'GOOGLE_PLAY_SERVICE_ACCOUNT_JSON';

Never _fail(String message) {
  stderr.writeln('play_upload: $message');
  exit(1);
}

Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('aab', help: 'Path to the signed app bundle.')
    ..addOption('package', help: 'applicationId, e.g. design.codeux.holdthewheel.')
    ..addOption('build-number', help: 'Expected versionCode; verified against the bundle.')
    ..addOption('version-name', help: 'Used only to name the release in the console.')
    ..addOption('track', defaultsTo: 'internal')
    ..addOption('status', defaultsTo: 'completed', help: 'completed | draft | inProgress')
    ..addOption('release-notes', help: 'Optional file whose contents become the en-GB notes.')
    ..addFlag('dry-run', negatable: false, help: 'Do everything except commit.')
    ..addFlag('help', abbr: 'h', negatable: false);

  final args = parser.parse(argv);
  if (args.flag('help')) {
    stdout.writeln(parser.usage);
    return;
  }

  final aabPath = args.option('aab');
  final packageName = args.option('package');
  final buildNumber = args.option('build-number');
  if (aabPath == null || packageName == null || buildNumber == null) {
    _fail('--aab, --package and --build-number are all required\n${parser.usage}');
  }

  final expectedVersionCode = int.tryParse(buildNumber);
  if (expectedVersionCode == null) {
    _fail('--build-number must be an integer, got "$buildNumber"');
  }

  final aab = File(aabPath);
  if (!aab.existsSync()) {
    _fail('no such file: $aabPath');
  }

  // Passed as JSON in the environment rather than a path, because that is what
  // tool/with-secrets.sh can supply without writing a credential to disk.
  final rawCredentials = Platform.environment[_serviceAccountVar];
  if (rawCredentials == null || rawCredentials.trim().isEmpty) {
    _fail(
      '$_serviceAccountVar is not set.\n'
      '  It holds the Google Play service account JSON. Run this through\n'
      '  tool/with-secrets.sh, or export it yourself.',
    );
  }

  final ServiceAccountCredentials credentials;
  try {
    credentials = ServiceAccountCredentials.fromJson(
      jsonDecode(rawCredentials) as Map<String, dynamic>,
    );
  } on FormatException catch (e) {
    _fail('$_serviceAccountVar is not valid JSON: ${e.message}');
  }

  final dryRun = args.flag('dry-run');
  final track = args.option('track')!;
  final versionName = args.option('version-name') ?? buildNumber;

  String? releaseNotes;
  final notesPath = args.option('release-notes');
  if (notesPath != null) {
    final f = File(notesPath);
    if (!f.existsSync()) {
      _fail('no such release notes file: $notesPath');
    }
    releaseNotes = f.readAsStringSync().trim();
    // Play rejects notes over 500 characters for a release, and does so after
    // the bundle has already been uploaded.
    if (releaseNotes.length > 500) {
      _fail('release notes are ${releaseNotes.length} characters; Play allows 500');
    }
  }

  final client = await clientViaServiceAccount(
    credentials,
    [AndroidPublisherApi.androidpublisherScope],
  );

  final api = AndroidPublisherApi(client);
  String? editId;

  try {
    final edit = await api.edits.insert(AppEdit(), packageName);
    editId = edit.id;
    if (editId == null) {
      _fail('Play did not return an edit id');
    }
    stdout.writeln('==> opened edit $editId');

    // Resumable rather than a single PUT: this is tens of megabytes, and a
    // simple upload that fails at 90% has to start over. Resumable also retries
    // with exponential backoff on its own.
    final media = Media(
      aab.openRead(),
      aab.lengthSync(),
      contentType: 'application/octet-stream',
    );
    stdout.writeln('==> uploading ${aab.lengthSync()} bytes');
    final bundle = await api.edits.bundles.upload(
      packageName,
      editId,
      uploadMedia: media,
      uploadOptions: UploadOptions.resumable,
    );

    final versionCode = bundle.versionCode;
    stdout.writeln('==> Play accepted versionCode $versionCode');

    // The versionCode is baked into the bundle at build time from
    // --build-number. If Play reports a different one, the artifact is not the
    // one that was just built, and assigning it to a track would publish
    // something nobody verified.
    if (versionCode != expectedVersionCode) {
      _fail(
        'versionCode mismatch: the bundle contains $versionCode but the build '
        'says $expectedVersionCode.\n'
        '  dist/ is stale, or the .aab was built from a different commit.',
      );
    }

    await api.edits.tracks.update(
      Track(
        track: track,
        releases: [
          TrackRelease(
            name: '$versionName ($versionCode)',
            versionCodes: ['$versionCode'],
            status: args.option('status'),
            releaseNotes: releaseNotes == null
                ? null
                : [LocalizedText(language: 'en-GB', text: releaseNotes)],
          ),
        ],
      ),
      packageName,
      editId,
      track,
    );
    stdout.writeln('==> assigned to track "$track" (${args.option('status')})');

    if (dryRun) {
      await api.edits.delete(packageName, editId);
      editId = null;
      stdout.writeln('==> dry run — edit discarded, nothing published');
      return;
    }

    await api.edits.commit(packageName, editId);
    editId = null;
    stdout.writeln('==> committed — $versionName ($versionCode) is on "$track"');
  } on DetailedApiRequestError catch (e) {
    // The default toString is a single dense line; the message is the part that
    // says what Play actually objected to.
    _fail('Play API error ${e.status}: ${e.message}');
  } finally {
    // An edit left open is harmless — Play expires them — but leaving one
    // behind means the next run sees a stale draft in the console for no
    // reason. Only reached when something threw before commit or delete.
    if (editId != null) {
      try {
        await api.edits.delete(packageName, editId);
        stdout.writeln('==> abandoned edit $editId');
      } catch (_) {
        // Losing the cleanup is not worth masking the original failure.
      }
    }
    client.close();
  }
}
