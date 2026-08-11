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
const _knownKeys = {'app-dir'};

/// What `.cux-ship.yaml` said, if a repository has one.
class ProjectConfig {
  const ProjectConfig({this.appDir});

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

    return ProjectConfig(appDir: _string(document, 'app-dir'));
  }

  /// Where the Flutter app lives, when it is not the repository root.
  ///
  /// The same value `--app-dir` takes, and overridden by it.
  final String? appDir;

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
