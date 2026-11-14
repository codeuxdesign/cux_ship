// SPDX-License-Identifier: Apache-2.0
//
// The record half of a release, as functions — an annotated git tag naming the
// commit something reached, written once and never moved.
//
//   import 'package:cux_ship/provenance.dart';
//
//   final git = Git(checkoutRoot);
//   final commit = taggedCommit(git, 'uploaded/v1.9.13+2196');
//   if (commit == null) {
//     throw StateError('build 2196 was never uploaded from here');
//   }
//   final result = recordUpload(
//     git,
//     UploadRecord(
//       name: 'promoted/huawei/production/v1.9.13+2196',
//       commit: commit,
//       annotation: 'build 2196 of 1.9.13\nhuawei production, by hand',
//     ),
//     failedPushIsFatal: false,
//   );
//
// **This is a write, and `read-api.md` says the exported surface is reads
// only — so the exception needs its reason stated rather than assumed.** That
// rule has two arguments behind it and neither reaches here. "The printed
// command line is what makes a failed release step resumable by hand" is about
// a *store* write: a stage that failed after `upload.sh` prints an invocation
// somebody re-runs, and an in-process call prints a stack trace instead. The
// equivalent here is `git tag -a` and `git push`, which a person already knows
// how to run and which this does not hide. "Per-step `secrets exec --only …`
// keeps a credential out of a step with no use for it" is about a narrowable
// secret; pushing a tag uses whatever git credential the checkout already has,
// and there is nothing to narrow. Nothing exported here uploads, promotes,
// publishes a listing or moves a build between tracks. It writes a tag.
//
// **What it actually fixes is a guarantee implemented twice, which this
// package already complained about in prose.** [recordUploadIfConfigured]'s own
// doc describes the earlier design — "each consuming repository write its own
// record from a shell wrapper for one store and let `cux_ship` do the other —
// one guarantee implemented twice, in two languages" — as the thing that made
// the refusal worthless. That is the live state of `promoted/` tags: How It
// Went's `tool/record-promotion.sh` is 125 lines of bash whose header says a
// tag naming a different commit "refuses, like cux_ship", which is a second
// implementation of this file's hardest-won behaviour, in a language with no
// way to share it. So this export is the argument `read-api.md` makes *for* the
// reads — "the export makes the promise explicit and small instead of implicit
// and total" — applied to the one write that was already being reimplemented.
//
// **The caller owns the tag name.** [UploadRecord] has said so since it was
// written, and that is what makes one function serve both namespaces:
// `uploaded/` is this package's own convention, `promoted/<destination>/<stage>/
// v{version}+{build}` is the train's, and neither is encoded here. A consumer
// inventing a third needs no change to this file.
//
// **Read [recordUpload]'s `failedPushIsFatal` before writing a promotion.** It
// is the one behavioural difference between a record written before its event
// and one written after it, and the default is the before case.
library;

export 'src/provenance.dart'
    show
        UploadCollisionException,
        UploadRecord,
        UploadRecordResult,
        recordUpload,
        uploadCollisionExit;
export 'src/release.dart' show Git, ReleaseException, taggedCommit;
