// SPDX-License-Identifier: Apache-2.0
//
// `.cux-ship.yaml` — what is true of a repository rather than of an invocation.
//
// Everything here could be a flag, and every key is one. The reason the file
// exists is that some of those flags never vary: a monorepo's app directory is
// the same on every command, forever, and typing it each time means a shell
// script repeating one constant at eight call sites. That is the shape
// ProjectContext was written to remove, and a flag-only answer puts a small
// version of it straight back.
//
// So the rule is the same one the rest of the tool follows: **read what can be
// read, and let a flag override it.** Precedence is flag, then CUX_SHIP_APP_DIR,
// then this file, then inference.
//
// It sits beside `.sops.yaml` at the repository root and is spelled like it.
//
// **An unknown key is an error, not a value to ignore.** The file's whole job is
// to be read silently before every command, so a misspelt key that is quietly
// skipped is a setting that appears to be applied and is not — which is the one
// failure this tool is built to refuse everywhere else. There is one key today,
// so the check costs nothing and the habit is set before there are ten.
import 'dart:io';

import 'package:yaml/yaml.dart';

import 'project.dart';

/// The name every consumer uses. Not configurable — a config file whose
/// location is configurable has to be found before it can be read.
const cuxShipConfigFile = '.cux-ship.yaml';

/// Keys this version understands. Anything else stops the command and is
/// reported against this list.
const _knownKeys = {'app-dir', 'apple'};

/// Keys understood inside `apple:`.
const _knownAppleKeys = {'signing'};

/// How provisioning profiles are come by, which decides more than it sounds
/// like it does.
///
/// `-allowProvisioningUpdates` is a portal *write*, and an individual App Store
/// Connect key cannot even read the portal — certificates, identifiers and
/// profiles are team resources, refused whatever role the user holds. So
/// automatic signing requires a team Admin key, and a team Admin key reaches
/// every app in the team.
///
/// Manual signing is therefore what buys a scoped CI credential: the stored
/// profiles are the price of a key that cannot touch anything but this app.
/// That is a reason to choose it on a new project, not merely a legacy state to
/// migrate away from.
enum AppleSigning {
  /// Xcode creates and renews profiles. Needs a team key.
  automatic,

  /// Profiles are supplied, from `apple.profiles` in the secrets file.
  manual,
}

/// What `.cux-ship.yaml` said, if a repository has one.
class ProjectConfig {
  const ProjectConfig({this.appDir, this.signing = AppleSigning.automatic});

  /// Reads `<repoRoot>/.cux-ship.yaml`.
  ///
  /// An absent file is not an error and yields an empty config — most projects
  /// need nothing here, and requiring the file would make the ordinary case
  /// pay for the monorepo one.
  ///
  /// Everything else is: an unreadable file, a document that is not a mapping,
  /// an unknown key, or a key of the wrong type all throw. This is read before
  /// every command, so anything wrong with it is wrong on every command, and
  /// saying so once is cheaper than a store command behaving unexpectedly.
  factory ProjectConfig.read(String repoRoot) {
    final file = File('$repoRoot/$cuxShipConfigFile');
    if (!file.existsSync()) {
      return const ProjectConfig();
    }

    final dynamic document;
    try {
      document = loadYaml(file.readAsStringSync(), sourceUrl: file.uri);
    } on YamlException catch (e) {
      throw ProjectException('$cuxShipConfigFile is not valid YAML: $e');
    }

    // An empty file parses to null, and is a legitimate thing to have — a file
    // whose every key has been commented out is still a file somebody meant to
    // keep.
    if (document == null) {
      return const ProjectConfig();
    }
    if (document is! YamlMap) {
      throw ProjectException(
        '$cuxShipConfigFile must be a mapping of settings, and is a '
        '${document.runtimeType}',
      );
    }

    final unknown =
        document.keys
            .map((k) => '$k')
            .where((k) => !_knownKeys.contains(k))
            .toList()
          ..sort();
    if (unknown.isNotEmpty) {
      throw ProjectException(
        '$cuxShipConfigFile has ${unknown.length == 1 ? 'an unknown key' : 'unknown keys'}: '
        '${unknown.join(', ')}\n'
        '    known keys: ${(_knownKeys.toList()..sort()).join(', ')}',
      );
    }

    return ProjectConfig(
      appDir: _string(document, 'app-dir'),
      signing: _apple(document),
    );
  }

  /// Where the Flutter app lives, when it is not the repository root.
  ///
  /// The same value `--app-dir` takes, and overridden by it.
  final String? appDir;

  /// How Apple provisioning profiles are come by. See [AppleSigning].
  final AppleSigning signing;

  /// Reads and cross-checks the `apple:` block.
  ///
  /// Both checks live here, in plaintext, on purpose: they are the half of the
  /// design that can be evaluated with no identity and on any platform.
  /// Everything about a profile *blob* — whether it parses, which platform it
  /// is for — needs `security cms -D` and therefore a Mac, so a Linux run must
  /// still be able to tell a consumer that its configuration disagrees with
  /// itself.
  static AppleSigning _apple(YamlMap document) {
    final apple = document['apple'];
    if (apple == null) {
      return AppleSigning.automatic;
    }
    if (apple is! YamlMap) {
      throw ProjectException(
        '$cuxShipConfigFile: apple must be a mapping, and is a '
        '${apple.runtimeType}',
      );
    }

    final unknown =
        apple.keys
            .map((k) => '$k')
            .where((k) => !_knownAppleKeys.contains(k))
            .toList()
          ..sort();
    if (unknown.isNotEmpty) {
      throw ProjectException(
        '$cuxShipConfigFile: apple has '
        '${unknown.length == 1 ? 'an unknown key' : 'unknown keys'}: '
        '${unknown.join(', ')}\n'
        '    known keys: ${(_knownAppleKeys.toList()..sort()).join(', ')}',
      );
    }

    final signing = switch (_string(apple, 'signing')) {
      null || 'automatic' => AppleSigning.automatic,
      'manual' => AppleSigning.manual,
      final other => throw ProjectException(
        '$cuxShipConfigFile: apple.signing must be automatic or manual, '
        'and is $other',
      ),
    };
    return signing;
  }

  static String? _string(YamlMap map, String key) {
    final value = map[key];
    if (value == null) {
      return null;
    }
    if (value is! String) {
      throw ProjectException(
        '$cuxShipConfigFile: $key must be a string, and is a '
        '${value.runtimeType}',
      );
    }
    return value;
  }
}
