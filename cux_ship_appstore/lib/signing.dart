// SPDX-License-Identifier: Apache-2.0

// What the developer account holds: certificates, App IDs and profiles.
//
// Nothing here uploads or releases, which makes it the odd one out in this
// package. It is here because automatic signing — `xcodebuild
// -allowProvisioningUpdates`, and Xcode whenever it signs a device build —
// registers whatever it needs without saying so, and that accumulates silently
// until something fails in a way that does not name the cause. A registration
// refused with "An App ID with Identifier … is not available" usually means
// Xcode created that id months ago for a target that has since been renamed.
//
// Ranked by how much the drift actually costs:
//
//   certificates  the only capped category, and the only one shared by every
//                 app in the team. Exhaust the cap and nothing signs — for any
//                 app, not just the one being worked on.
//   profiles      free and auto-renewing. Expired ones are noise, not breakage,
//                 but they make the console unreadable.
//   app ids       free and harmless in themselves.
//
// Pure functions over Apple's JSON. The network lives in cli.dart, so all of
// this is testable against fixtures.

/// Apple publishes no exact figure and public sources disagree between two and
/// three. Warned about rather than enforced: the point is to notice before a
/// build fails, not to be right about a number Apple can change.
const distributionCertificateWarnAt = 2;

/// Xcode names what it registers `XC <dotted bundle id>`. Nothing else does.
const _autoCreatedNamePrefix = 'XC ';

/// How close to expiry is worth pointing out.
const _soonInDays = 30;

/// One certificate, App ID or profile, reduced to what an audit cares about.
extension AscAttributes on Map<String, dynamic> {
  String? attr(String name) {
    final attributes = this['attributes'];
    return attributes is Map<String, dynamic>
        ? attributes[name] as String?
        : null;
  }
}

/// Whole-account state, already classified.
class SigningAudit {
  SigningAudit({
    required this.certificates,
    required this.bundleIds,
    required this.profiles,
    required this.ourPrefix,
    required this.now,
  });

  final List<Map<String, dynamic>> certificates;
  final List<Map<String, dynamic>> bundleIds;
  final List<Map<String, dynamic>> profiles;

  /// Bundle ids starting with this belong to the project being audited.
  /// Everything else is still listed — a shared certificate means another
  /// app's drift is this app's problem — just not attributed here.
  final String? ourPrefix;

  /// Injected so the expiry arithmetic is testable.
  final DateTime now;

  Map<String, List<Map<String, dynamic>>> get certificatesByType {
    final byType = <String, List<Map<String, dynamic>>>{};
    for (final certificate in certificates) {
      byType
          .putIfAbsent(certificate.attr('certificateType') ?? '?', () => [])
          .add(certificate);
    }
    for (final certs in byType.values) {
      certs.sort(
        (a, b) => (a.attr('expirationDate') ?? '').compareTo(
          b.attr('expirationDate') ?? '',
        ),
      );
    }
    return byType;
  }

  int get distributionCertificateCount =>
      certificatesByType['DISTRIBUTION']?.length ?? 0;

  bool get distributionCapWorthWarningAbout =>
      distributionCertificateCount >= distributionCertificateWarnAt;

  static bool isAutoCreated(Map<String, dynamic> bundleId) =>
      (bundleId.attr('name') ?? '').startsWith(_autoCreatedNamePrefix);

  List<Map<String, dynamic>> get autoCreatedBundleIds =>
      bundleIds.where(isAutoCreated).toList();

  bool isOurs(Map<String, dynamic> bundleId) {
    final prefix = ourPrefix;
    if (prefix == null) {
      return false;
    }
    final identifier = bundleId.attr('identifier') ?? '';
    return identifier == prefix || identifier.startsWith('$prefix.');
  }

  List<Map<String, dynamic>> get ourBundleIds =>
      (bundleIds.where(isOurs).toList())..sort(_byIdentifier);

  List<Map<String, dynamic>> get otherBundleIds =>
      (bundleIds.where((b) => !isOurs(b)).toList())..sort(_byIdentifier);

  List<Map<String, dynamic>> get profilesByName =>
      (List<Map<String, dynamic>>.from(profiles))..sort(
        (a, b) => (a.attr('name') ?? '').compareTo(b.attr('name') ?? ''),
      );

  int get inactiveProfileCount =>
      profiles.where((p) => p.attr('profileState') != 'ACTIVE').length;

  int get expiringProfileCount => profiles.where((p) {
    final days = daysUntil(p.attr('expirationDate'));
    return days != null && days <= _soonInDays;
  }).length;

  static int _byIdentifier(Map<String, dynamic> a, Map<String, dynamic> b) =>
      (a.attr('identifier') ?? '').compareTo(b.attr('identifier') ?? '');

  /// Whole days from [now] until [date], negative once past. Null when Apple
  /// omitted the field or sent something unparseable.
  int? daysUntil(String? date) {
    if (date == null) {
      return null;
    }
    return DateTime.tryParse(date)?.difference(now).inDays;
  }

  /// A short suffix for a line that has an expiry, or nothing at all.
  String expiryNote(String? date) {
    final days = daysUntil(date);
    if (days == null) {
      return '';
    }
    if (days < 0) {
      return '  ** EXPIRED ${-days}d ago **';
    }
    if (days <= _soonInDays) {
      return '  ** expires in ${days}d **';
    }
    return '  (${days}d left)';
  }
}

/// The longest dotted prefix shared by an app and its extensions.
///
/// An extension's bundle id must be prefixed by its host app's, so
/// `design.codeux.authpass.ios` covers `design.codeux.authpass.ios.autofill`
/// without naming it. Derived rather than configured, because a project that
/// gained a target should not have to remember to update an audit.
String? projectPrefix(String? bundleId) {
  final trimmed = bundleId?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}
