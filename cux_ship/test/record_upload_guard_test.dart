// SPDX-License-Identifier: Apache-2.0
//
// The guard that decides whether an upload records itself.
//
// It read `ArgResults.options`, which holds what was *provided or defaulted* —
// while the question it meant to ask is what the subcommand *declares*. So
// `record-uploads: true` recorded nothing unless `--commit` was typed by hand,
// which is every caller using `--manifest`: the flag whose entire purpose is
// supplying that commit.
//
// Nothing failed. The guard returns early and silently, so the configuration
// read as working for as long as nobody went looking for the tag. It was found
// by turning the feature on in a real repository, uploading, and finding no tag
// — not by any test, because no test asked what the two `options` mean.
import 'package:cux_ship/runner.dart';
import 'package:test/test.dart';

void main() {
  test('a declared but unpassed --commit is still declared', () {
    // The distinction the guard turned on, pinned directly: these two disagree
    // exactly when an option exists and was not given, which is the case that
    // matters.
    final upload = buildRunner().commands['play']!.subcommands['upload']!;
    final parsed = upload.argParser.parse([
      '--manifest',
      '/dist/manifest.json',
      '--track',
      'internal',
    ]);

    expect(
      upload.argParser.options.containsKey('commit'),
      isTrue,
      reason: 'declared — this is what the guard must ask',
    );
    expect(
      parsed.options.contains('commit'),
      isFalse,
      reason:
          'not provided and has no default — this is what it used to ask, '
          'and why recording never happened through --manifest',
    );
  });

  test('both upload subcommands declare --commit', () {
    // The guard skips a parser that never declared it, which is correct and is
    // why it cannot simply be deleted. These are the two that must not be
    // skipped.
    final runner = buildRunner();
    for (final store in ['play', 'appstore']) {
      expect(
        runner.commands[store]!.subcommands['upload']!.argParser.options
            .containsKey('commit'),
        isTrue,
        reason: '$store upload must be able to record',
      );
    }
  });

  test('promote does not record, and is skipped by name', () {
    // A promote moves a build the store already holds; it is not the moment
    // anything was published from this repository.
    final runner = buildRunner();
    for (final store in ['play', 'appstore']) {
      expect(runner.commands[store]!.subcommands['promote']!.name, 'promote');
    }
  });
}
