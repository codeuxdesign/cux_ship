// SPDX-License-Identifier: Apache-2.0

// Fetching and printing the signing audit. The classification lives in
// signing.dart, which knows nothing about the network.
//
// **This is the one command that needs an Admin key.** Everything else here
// works with App Manager, because uploading a build and editing a listing are
// App Store Connect operations. Certificates, identifiers and profiles are the
// developer *portal*, which Apple gates separately, and an App Manager key is
// refused with a 403 that names none of this. So each fetch is allowed to fail
// on its own: a key that can read some of the three still produces a useful
// report of that part, with the rest named as refused rather than silently
// absent. An audit that quietly omitted a section would be worse than one that
// failed outright.

import 'dart:io';

import 'asc_client.dart';
import 'signing.dart';

/// What a single fetch produced, or why it did not.
class _Fetched {
  _Fetched.ok(this.rows) : refused = false;
  _Fetched.refused() : rows = const [], refused = true;

  final List<Map<String, dynamic>> rows;

  /// Apple answered 401/403 — a permissions answer, not an empty account.
  final bool refused;
}

/// Reads the account and writes the report to stdout.
///
/// Returns false when nothing at all could be read, which is a failure of the
/// credential rather than a finding about the account. Individual sections
/// being refused is reported and still returns true — there is a real report.
Future<bool> reportSigning(
  AscClient client, {
  String? bundleId,
  DateTime? now,
}) async {
  if (client.credentials.isIndividual) {
    stderr.writeln(
      'This is an individual API key, which cannot read the developer portal '
      'at all —\n'
      'certificates, identifiers and profiles are refused whatever role the '
      'user has.\n'
      'They are team resources and an individual key is scoped to apps.\n'
      '\n'
      'Use a team key with the Admin role for this command. An individual key '
      'is the\n'
      'right one for uploading, where scoping it to particular apps is the '
      'whole point.',
    );
    return false;
  }

  final certificates = await _fetch(client, '/v1/certificates', 'certificates');
  final bundleIds = await _fetch(client, '/v1/bundleIds', 'App IDs');
  final profiles = await _fetch(
    client,
    '/v1/profiles',
    'profiles',
    query: {'include': 'bundleId'},
  );

  if (certificates.refused && bundleIds.refused && profiles.refused) {
    stderr.writeln(
      '\nEvery request was refused, so this key cannot read the developer\n'
      'portal at all. Certificates, identifiers and profiles need a key with\n'
      'the **Admin** role; App Manager is enough for uploading and for the\n'
      'listing, and is what the other commands here use.\n'
      '\n'
      'App Store Connect > Users and Access > Integrations > Team Keys.\n'
      'A key\'s role cannot be changed after it is created — generate a new\n'
      'one and revoke the old.',
    );
    return false;
  }

  final audit = SigningAudit(
    certificates: certificates.rows,
    bundleIds: bundleIds.rows,
    profiles: profiles.rows,
    ourPrefix: projectPrefix(bundleId),
    now: now ?? DateTime.now(),
  );

  _certificates(audit, refused: certificates.refused);
  _bundleIds(audit, refused: bundleIds.refused);
  _profiles(audit, refused: profiles.refused);
  _summary(
    audit,
    refused: [
      if (certificates.refused) 'certificates',
      if (bundleIds.refused) 'App IDs',
      if (profiles.refused) 'profiles',
    ],
  );
  return true;
}

Future<_Fetched> _fetch(
  AscClient client,
  String path,
  String what, {
  Map<String, String>? query,
}) async {
  try {
    return _Fetched.ok(await client.getAll(path, query: query));
  } on AscApiException catch (e) {
    if (e.status == 401 || e.status == 403) {
      return _Fetched.refused();
    }
    rethrow;
  }
}

void _heading(String title) {
  stdout
    ..writeln()
    ..writeln('=' * 72)
    ..writeln(title)
    ..writeln('=' * 72);
}

void _refusedNote(String what) {
  stdout.writeln(
    '\n  Not readable with this key. $what need the Admin role; see the note\n'
    '  at the end.',
  );
}

void _certificates(SigningAudit audit, {required bool refused}) {
  _heading(
    'CERTIFICATES  — team wide, shared by every app, the only capped '
        'category.\n                Xcode-managed ones are not listed; Apple '
        'does not serve them.',
  );
  if (refused) {
    return _refusedNote('Certificates');
  }

  final byType = audit.certificatesByType;
  for (final type in byType.keys.toList()..sort()) {
    stdout.writeln('\n$type  (${byType[type]!.length})');
    for (final certificate in byType[type]!) {
      stdout.writeln(
        '  ${certificate['id']}  ${certificate.attr('displayName')}'
        '${audit.expiryNote(certificate.attr('expirationDate'))}',
      );
    }
  }

  if (audit.distributionCapWorthWarningAbout) {
    stdout.writeln(
      '\n  !! ${audit.distributionCertificateCount} distribution certificates '
      'visible here, usually\n'
      '     capped around 2-3. The cap is team wide, so if automatic signing\n'
      '     mints another, signing can break for every app in the team.\n'
      '     Supply the distribution certificate explicitly on CI so minting\n'
      '     one is never its only option.\n'
      '\n'
      '     That count is a floor, not a total: Apple does not return\n'
      '     Xcode-managed certificates here and refuses to be asked for them,\n'
      '     so only the portal shows how close the cap really is.',
    );
  }
}

void _bundleIds(SigningAudit audit, {required bool refused}) {
  _heading('APP IDS  — "XC …" means automatic signing created it, not a human');
  if (refused) {
    return _refusedNote('Identifiers');
  }

  if (audit.ourPrefix != null) {
    final ours = audit.ourBundleIds;
    stdout.writeln('\nthis project (${ours.length}):');
    for (final bundleId in ours) {
      final marker = SigningAudit.isAutoCreated(bundleId)
          ? '  [auto-created]'
          : '';
      stdout.writeln('  ${bundleId.attr('identifier')}$marker');
    }
    stdout.writeln('\nrest of the account (${audit.otherBundleIds.length}):');
  } else {
    stdout.writeln('\nall (${audit.otherBundleIds.length}):');
  }
  for (final bundleId in audit.otherBundleIds) {
    stdout.writeln('  ${bundleId.attr('identifier')}');
  }

  final autoCreated = audit.autoCreatedBundleIds.length;
  if (autoCreated > 0) {
    stdout.writeln(
      '\n  $autoCreated auto-created. Harmless in themselves — but one left\n'
      '  over from a renamed target is why registering an id by hand can fail\n'
      '  with "is not available". Worth pruning the ones nothing builds.',
    );
  }
}

void _profiles(SigningAudit audit, {required bool refused}) {
  _heading('PROFILES');
  if (refused) {
    return _refusedNote('Profiles');
  }

  for (final profile in audit.profilesByName) {
    final state = profile.attr('profileState');
    stdout
      ..writeln('  ${profile.attr('name')}')
      ..writeln(
        '      ${profile.attr('profileType')}'
        '${state == 'ACTIVE' ? '' : '  [$state]'}'
        '${audit.expiryNote(profile.attr('expirationDate'))}',
      );
  }
}

void _summary(SigningAudit audit, {required List<String> refused}) {
  _heading('SUMMARY');
  stdout
    ..writeln(
      '  certificates        ${audit.certificates.length} '
      '(${audit.distributionCertificateCount} distribution)',
    )
    ..writeln(
      '  app ids             ${audit.bundleIds.length} '
      '(${audit.autoCreatedBundleIds.length} auto-created)',
    )
    ..writeln(
      '  profiles            ${audit.profiles.length} '
      '(${audit.inactiveProfileCount} not active, '
      '${audit.expiringProfileCount} expiring within 30d)',
    );

  if (refused.isNotEmpty) {
    stdout.writeln(
      '\n  ${refused.join(' and ')} could not be read: this key lacks the\n'
      '  Admin role. Those counts are 0 because nothing was returned, not\n'
      '  because nothing exists.',
    );
  }

  stdout.writeln(
    '\n  Nothing was changed. Prune from the portal, or with Xcode: anything\n'
    '  automatic signing still needs, it recreates on the next build.',
  );
}
