// SPDX-License-Identifier: Apache-2.0
//
// Fetching the two binaries the secrets path needs — sops and age — into
// `.bin/` at the repository root.
//
// Project-local rather than system-wide, so a laptop and a CI runner run the
// same bytes and neither needs a package manager. Both are single static Go
// binaries with no runtime of their own, which is what makes this practical and
// a large part of why they were chosen.
//
// Downloads land in `<dest>.part` and are only verified-then-moved, so an
// interrupted or tampered fetch cannot be picked up as installed on the next
// run. There is no partially-installed state to reason about.
//
// The pins are in deps_pins.dart. `update` rewrites that file, which means it
// only works inside a cux_ship checkout — a consumer gets new pins by moving
// the ref it depends on, which is the point of the pins living here at all.
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'deps_pins.dart';
import 'project.dart';

/// What `cux_ship deps` can be asked to do.
enum DepsCommand { install, check, update }

/// The tools this manages, in the order they are reported.
const _tools = ['sops', 'age'];

/// Where a tool's releases live.
const _repos = {'sops': 'getsops/sops', 'age': 'FiloSottile/age'};

/// This machine, as `(darwin|linux)` and `(arm64|amd64)`.
///
/// From [Abi] rather than `uname`, which is a process spawn to learn something
/// the VM already knows — and `uname -m` says x86_64/aarch64 while both these
/// projects publish amd64/arm64, so the shell version had to translate anyway.
({String os, String arch}) currentPlatform() => switch (Abi.current()) {
  Abi.macosArm64 => (os: 'darwin', arch: 'arm64'),
  Abi.macosX64 => (os: 'darwin', arch: 'amd64'),
  Abi.linuxArm64 => (os: 'linux', arch: 'arm64'),
  Abi.linuxX64 => (os: 'linux', arch: 'amd64'),
  // **amd64 only, deliberately.** sops publishes `arm64.exe` but age publishes
  // no windows-arm64 archive at all, so a pin for it could not be completed —
  // and half a toolchain is worse than the message below, which at least says
  // what to do.
  Abi.windowsX64 => (os: 'windows', arch: 'amd64'),
  final other => throw ProjectException(
    'no sops or age build is pinned for $other — install both yourself and '
    'put them on PATH',
  ),
};

/// Asset naming differs between the two projects: sops uses dots, age dashes.
///
/// **And sops names its Windows builds by architecture alone.** The asset is
/// `sops-v3.13.3.amd64.exe`, with no `windows` anywhere in it, while every
/// other platform is `sops-v3.13.3.<os>.<arch>`. So the `os.arch` rule this
/// function otherwise implements produces a URL that 404s — the one place the
/// two projects' conventions diverge from their own.
String platformFor(String tool, ({String os, String arch}) host) {
  if (tool == 'sops') {
    return host.os == 'windows'
        ? '${host.arch}.exe'
        : '${host.os}.${host.arch}';
  }
  return '${host.os}-${host.arch}';
}

/// age ships a zip for Windows and a tar.gz everywhere else.
String ageArchiveExtension(String platform) =>
    platform.startsWith('windows') ? 'zip' : 'tar.gz';

/// What an executable is called on this machine.
///
/// Windows will not run a file without the extension, so the name is part of
/// the install rather than a cosmetic detail: `sops` on disk is `sops.exe`
/// there, and every lookup of it has to agree.
String exeName(String name) => Platform.isWindows ? '$name.exe' : name;

/// The pinned version of [tool], and the hash for this machine's build.
ToolPin pinFor(String tool, ({String os, String arch}) host) {
  final platform = platformFor(tool, host);
  for (final pin in depsPins) {
    if (pin.tool == tool && pin.platform == platform) {
      return pin;
    }
  }
  throw ProjectException(
    'no $tool build is pinned for $platform — run `cux_ship deps update` in a '
    'cux_ship checkout',
  );
}

/// The version of [tool] already in [binDir], or null when it is not there.
///
/// sops asks a remote service for the newest version unless told not to, which
/// would make this hang on an offline machine instead of answering.
String? installedVersion(String binDir, String tool) {
  final exe = File('$binDir/${exeName(tool)}');
  if (!exe.existsSync()) {
    return null;
  }
  final args = tool == 'sops'
      ? ['--version', '--disable-version-check']
      : ['--version'];
  final ProcessResult result;
  try {
    result = Process.runSync(exe.path, args);
  } on ProcessException {
    return null;
  }
  final text = '${result.stdout}${result.stderr}';
  return RegExp(r'\d+\.\d+\.\d+').firstMatch(text)?.group(0);
}

/// Runs `cux_ship deps <command>`, returning the process exit code.
Future<int> runDeps(
  DepsCommand command, {
  required String binDir,
  void Function(String) log = print,
}) async {
  final host = currentPlatform();

  if (command == DepsCommand.update) {
    await _update(log);
    return 0;
  }

  final missing = <String>[];
  for (final tool in _tools) {
    final pin = pinFor(tool, host);
    final have = installedVersion(binDir, tool);
    // age ships two binaries and only one carries a version, so the second is
    // checked for existence rather than being assumed to have come with it.
    final complete =
        have == pin.version &&
        (tool != 'age' ||
            File('$binDir/${exeName('age-keygen')}').existsSync());
    if (complete) {
      log('$tool ${pin.version}: ok');
      continue;
    }
    missing.add(tool);
    log('$tool ${pin.version}: ${have == null ? 'missing' : 'have $have'}');
  }

  if (command == DepsCommand.check) {
    return missing.isEmpty ? 0 : 1;
  }

  Directory(binDir).createSync(recursive: true);
  for (final tool in missing) {
    final pin = pinFor(tool, host);
    log('fetching $tool ${pin.version} (${pin.platform})');
    if (tool == 'sops') {
      await _installSops(binDir, pin);
    } else {
      await _installAge(binDir, pin);
    }
  }
  log(
    'sops ${installedVersion(binDir, 'sops')}, '
    'age ${installedVersion(binDir, 'age')} in $binDir',
  );
  return 0;
}

// ------------------------------------------------------------------ fetching

/// Downloads [url] to [dest], and moves it into place only once its hash is
/// [wantSha256].
///
/// The `.part` file is the whole design: a download that fails, is truncated,
/// or is tampered with never becomes an executable at the destination name, so
/// the next run sees "not installed" rather than "installed and wrong".
Future<void> fetchVerified(String url, File dest, String wantSha256) async {
  final part = File('${dest.path}.part');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw ProjectException('download failed (${response.statusCode}): $url');
    }
    await response.pipe(part.openWrite());
  } on ProjectException {
    if (part.existsSync()) {
      part.deleteSync();
    }
    rethrow;
  } on Exception catch (e) {
    if (part.existsSync()) {
      part.deleteSync();
    }
    throw ProjectException('download failed: $url\n    $e');
  } finally {
    client.close();
  }

  final got = await sha256OfFile(part);
  if (got != wantSha256) {
    part.deleteSync();
    throw ProjectException(
      'checksum mismatch for $url\n'
      '    expected $wantSha256\n'
      '    got      $got\n'
      'If upstream legitimately republished, re-pin with `cux_ship deps '
      'update` and review the diff.',
    );
  }
  part.renameSync(dest.path);
}

/// Streamed rather than read whole: a sops binary is ~50 MB and there is no
/// reason to hold it in memory to hash it.
Future<String> sha256OfFile(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

Future<void> _installSops(String binDir, ToolPin pin) async {
  final dest = File('$binDir/${exeName('sops')}');
  await fetchVerified(
    'https://github.com/${_repos['sops']}/releases/download/'
    'v${pin.version}/sops-v${pin.version}.${pin.platform}',
    dest,
    pin.sha256,
  );
  _makeExecutable(dest);
}

Future<void> _installAge(String binDir, ToolPin pin) async {
  final work = Directory.systemTemp.createTempSync('cux_ship_age');
  try {
    final extension = ageArchiveExtension(pin.platform);
    final archive = File('${work.path}/age.$extension');
    await fetchVerified(
      'https://github.com/${_repos['age']}/releases/download/'
      'v${pin.version}/age-v${pin.version}-${pin.platform}.$extension',
      archive,
      pin.sha256,
    );
    // Shelled out rather than pulling an archive library in: tar is on every
    // machine that can run the rest of this, and the hash above is what the
    // trust rests on either way.
    //
    // **`-xf` for the zip, because only bsdtar reads one.** Windows 10 and
    // later ship bsdtar as `tar`, which unpacks zip happily; GNU tar does not,
    // and never has to here, because the zip is the Windows asset. `-xzf` is
    // kept for the tarball rather than relying on both tars auto-detecting.
    final result = Process.runSync('tar', [
      extension == 'zip' ? '-xf' : '-xzf',
      archive.path,
      '-C',
      work.path,
    ]);
    if (result.exitCode != 0) {
      throw ProjectException('could not unpack age: ${result.stderr}');
    }
    // The archive holds both binaries under age/. age-keygen is the one that
    // makes an identity, so omitting it would leave first-time setup needing a
    // system install after all.
    //
    // Verified against the real Windows zip rather than assumed: it carries
    // `age/age.exe` and `age/age-keygen.exe` — the same `age/` prefix as the
    // tarball, with the extension the platform requires.
    for (final name in ['age', 'age-keygen']) {
      final source = File('${work.path}/age/${exeName(name)}');
      if (!source.existsSync()) {
        throw ProjectException('the age archive has no ${exeName(name)}');
      }
      final dest = source.copySync('$binDir/${exeName(name)}');
      _makeExecutable(dest);
    }
  } finally {
    work.deleteSync(recursive: true);
  }
}

/// Dart cannot set a mode, and these are downloaded to be run.
///
/// **Nothing to do on Windows, and no `chmod` there to do it with.** Windows
/// decides what is runnable from the extension rather than a mode bit, which
/// [exeName] has already supplied. Shelling out anyway would fail the install
/// on the one platform that needs no permission change at all.
void _makeExecutable(File file) {
  if (Platform.isWindows) {
    return;
  }
  final result = Process.runSync('chmod', ['755', file.path]);
  if (result.exitCode != 0) {
    throw ProjectException('could not make ${file.path} executable');
  }
}

// -------------------------------------------------------------------- update

/// Platforms pinned regardless of the machine doing the update, so a set
/// written on a Mac still serves a Linux runner.
const _updatePlatforms = [
  (os: 'darwin', arch: 'arm64'),
  (os: 'darwin', arch: 'amd64'),
  (os: 'linux', arch: 'amd64'),
  (os: 'linux', arch: 'arm64'),
  // Windows amd64 and not arm64: age publishes no windows-arm64 archive, so
  // the pass below would fail on it — and pinning half a toolchain is worse
  // than [currentPlatform]'s refusal, which says what to do instead.
  (os: 'windows', arch: 'amd64'),
];

Future<void> _update(void Function(String) log) async {
  final target = _pinsFile();

  final versions = <String, String>{};
  for (final tool in _tools) {
    versions[tool] = await _latestTag(_repos[tool]!);
  }
  log('latest: ${_tools.map((t) => '$t ${versions[t]}').join(', ')}');

  final pins = <ToolPin>[];

  // One fetch of the published manifest covers every sops platform at once.
  log('reading sops checksums');
  final sopsVersion = versions['sops']!;
  final sums = await _get(
    'https://github.com/${_repos['sops']}/releases/download/'
    'v$sopsVersion/sops-v$sopsVersion.checksums.txt',
  );
  for (final host in _updatePlatforms) {
    final platform = platformFor('sops', host);
    final line = LineSplitter.split(sums).firstWhere(
      (l) => l.trim().endsWith('sops-v$sopsVersion.$platform'),
      orElse: () => throw ProjectException(
        'sops $sopsVersion publishes no asset for $platform',
      ),
    );
    pins.add((
      tool: 'sops',
      version: sopsVersion,
      platform: platform,
      sha256: line.trim().split(RegExp(r'\s+')).first,
    ));
  }

  final ageVersion = versions['age']!;
  final work = Directory.systemTemp.createTempSync('cux_ship_deps_update');
  try {
    for (final host in _updatePlatforms) {
      final platform = platformFor('age', host);
      log('hashing age $ageVersion ($platform)');
      final extension = ageArchiveExtension(platform);
      final archive = File('${work.path}/age-$platform.$extension');
      // Downloaded only to be hashed: age publishes no checksum file, so the
      // hash is trust-on-first-use over HTTPS and this is where that trust is
      // established. Reviewing the diff is the other half of it.
      await _download(
        'https://github.com/${_repos['age']}/releases/download/'
        'v$ageVersion/age-v$ageVersion-$platform.$extension',
        archive,
      );
      pins.add((
        tool: 'age',
        version: ageVersion,
        platform: platform,
        sha256: await sha256OfFile(archive),
      ));
    }
  } finally {
    work.deleteSync(recursive: true);
  }

  target.writeAsStringSync(_renderPins(target.readAsStringSync(), pins));
  log(
    'wrote ${target.path} — review the diff, then run `cux_ship deps install`',
  );
}

/// The `deps_pins.dart` to rewrite.
///
/// Found by walking up from the working directory, because `deps update` is a
/// cux_ship maintenance command rather than a consumer one: a consumer's copy
/// lives in the pub cache, where rewriting it would be both wrong and
/// invisible on the next `pub get`.
File _pinsFile() {
  for (
    var dir = Directory.current.absolute;
    dir.parent.path != dir.path;
    dir = dir.parent
  ) {
    for (final candidate in [
      File('${dir.path}/lib/src/deps_pins.dart'),
      File('${dir.path}/cux_ship/lib/src/deps_pins.dart'),
    ]) {
      if (candidate.existsSync()) {
        return candidate;
      }
    }
  }
  throw ProjectException(
    '`deps update` rewrites cux_ship\'s own pins, and no deps_pins.dart was '
    'found above ${Directory.current.path}.\n'
    'Run it inside a cux_ship checkout. A project that consumes cux_ship gets '
    'new pins by moving the ref it depends on.',
  );
}

/// Refuses a pin field that does not look like what it claims to be.
///
/// Deliberately not an escape: a version or a hash that needs escaping is not
/// a version or a hash, and writing it out safely would only record upstream
/// having sent something inexplicable.
void _checkPinField(String field, String value, RegExp shape) {
  if (!shape.hasMatch(value)) {
    throw ProjectException(
      'refusing to write a pin whose $field does not look like one: "$value"\n'
      'It came from a GitHub release, so this means upstream published '
      'something unexpected. Do not hand-edit it in — find out why.',
    );
  }
}

/// Replaces the `depsPins` list, leaving the file's header comment alone —
/// that text explains where the hashes come from and is not regenerated.
String _renderPins(String existing, List<ToolPin> pins) {
  final marker = existing.indexOf('const depsPins = <ToolPin>[');
  if (marker < 0) {
    throw ProjectException(
      'deps_pins.dart has no `const depsPins = <ToolPin>[` to replace',
    );
  }
  final buffer = StringBuffer(existing.substring(0, marker))
    ..writeln('const depsPins = <ToolPin>[');
  for (final pin in pins) {
    // Checked before being written into source, because both values arrive
    // from the network — the version from GitHub's `tag_name`, the hash from a
    // published checksums.txt — and land inside single quotes in a .dart file
    // that the next `analyze` or `build` compiles. A value carrying a quote
    // would close the literal and inject code.
    //
    // The path is narrow: `deps update` is a maintainer command, run in a
    // cux_ship checkout, over TLS, and the diff is meant to be reviewed. It
    // needs an upstream release-asset compromise *and* a reviewer who misses
    // it. Two regexes are cheaper than relying on the second half of that.
    _checkPinField('version', pin.version, RegExp(r'^[0-9][0-9A-Za-z.+-]*$'));
    _checkPinField('sha256', pin.sha256, RegExp(r'^[0-9a-f]{64}$'));
    _checkPinField(
      'platform',
      pin.platform,
      RegExp(r'^[a-z0-9]+[.-][a-z0-9]+$'),
    );
    buffer
      ..writeln('  (')
      ..writeln("    tool: '${pin.tool}',")
      ..writeln("    version: '${pin.version}',")
      ..writeln("    platform: '${pin.platform}',")
      ..writeln("    sha256: '${pin.sha256}',")
      ..writeln('  ),');
  }
  buffer.writeln('];');
  return buffer.toString();
}

Future<String> _latestTag(String repo) async {
  final body = await _get('https://api.github.com/repos/$repo/releases/latest');
  final tag = (jsonDecode(body) as Map<String, dynamic>)['tag_name'] as String?;
  if (tag == null || tag.isEmpty) {
    throw ProjectException('could not read the latest release of $repo');
  }
  return tag.startsWith('v') ? tag.substring(1) : tag;
}

Future<String> _get(String url) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    // The releases API answers 403 to a request with no user agent.
    request.headers.set(HttpHeaders.userAgentHeader, 'cux_ship');
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw ProjectException('GET $url returned ${response.statusCode}');
    }
    // Awaited, so the body is drained before `finally` closes the client.
    // Returning the future unawaited hands the caller a stream to read from a
    // client that has already been closed. `close()` waits for in-flight
    // requests, which is why this worked — but the ordering was wrong, and the
    // sibling `_download` below never had it. Dart 3.13's
    // `unawaited_return_in_try_block` is what surfaced it.
    return await response.transform(utf8.decoder).join();
  } finally {
    client.close();
  }
}

Future<void> _download(String url, File dest) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw ProjectException('GET $url returned ${response.statusCode}');
    }
    await response.pipe(dest.openWrite());
  } finally {
    client.close();
  }
}
