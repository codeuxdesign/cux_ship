// SPDX-License-Identifier: Apache-2.0
//
// Some of Apple's errors name a condition the API cannot fix. For those the
// useful reply is not the error text but where the work has to happen.

import 'package:cux_ship/src/appstore/asc_client.dart';
import 'package:test/test.dart';

void main() {
  group('guidance for errors that do not say what to do', () {
    // Apple's own wording, from a submission this blocked. Matching a real
    // string rather than a paraphrase is the point: a paraphrase tests that the
    // matcher agrees with the person who wrote it.
    const applesWords =
        'Unable to Add for Review — an Admin must provide information about '
        "the app's privacy practices in the App Privacy section.";

    test('the App Privacy refusal is explained', () {
      final guidance = AscApiException.guidanceFor([applesWords]);
      expect(guidance, isNotNull);
      expect(guidance, contains('Distribution > App Privacy'));
      // The two facts the error itself withholds, and which decide whether the
      // reader can act on it at all.
      expect(guidance, contains('Admin'));
      expect(guidance, contains('per app rather than per version'));
    });

    // The distinction worth keeping: this is not a missing feature, it is a
    // missing endpoint. Without saying so, the next reader goes looking for the
    // cux_ship flag that would fix it.
    test('it says the API cannot check this, rather than implying a gap', () {
      final guidance = AscApiException.guidanceFor([applesWords])!;
      expect(guidance, contains('absent from the App Store Connect API'));
      expect(guidance, contains('will not pretend'));
    });

    test('it reaches the printed error', () {
      final rendered = AscApiException(409, [
        applesWords,
      ], request: 'POST /v1/reviewSubmissionItems').toString();
      expect(rendered, contains('409'));
      expect(rendered, contains(applesWords));
      expect(rendered, contains('App Store Connect > your app'));
    });

    // Everything else is left alone. An error that already names its field is
    // actionable as printed, and appending a paragraph to all of them would
    // train people to stop reading the paragraph.
    test('an ordinary error gets nothing appended', () {
      expect(
        AscApiException.guidanceFor([
          'Entity Error.Attribute.Invalid - The provided entity includes an '
              'attribute with an invalid value (source: /data/attributes/'
              'versionString)',
        ]),
        isNull,
      );
      expect(AscApiException.guidanceFor(const []), isNull);
    });

    // Apple's title verbatim, from a live 422 answering a beta review
    // submission with no description — the code beside it,
    // ENTITY_UNPROCESSABLEMISSING_BETA_APP_DESCRIPTION, never reaches the
    // flattened details, so the title is what there is to match.
    test('the missing beta description names both remedies', () {
      final guidance = AscApiException.guidanceFor([
        'Beta App Description is missing.',
      ]);
      expect(guidance, isNotNull);
      expect(guidance, contains('beta_description.txt'));
      expect(guidance, contains('TestFlight > Test Information'));
    });
  });
}
