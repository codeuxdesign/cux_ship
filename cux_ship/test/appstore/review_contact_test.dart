// SPDX-License-Identifier: Apache-2.0
//
// The review contact is read from the environment rather than from the metadata
// tree, and everything worth testing about it is a refusal: Apple wants all four
// fields together and wants the phone in one particular shape, and both
// rejections otherwise arrive mid-push with several listing fields already
// written.
import 'package:cux_ship/src/appstore/app_store.dart';
import 'package:cux_ship/src/appstore/asc_client.dart';
import 'package:test/test.dart';

void main() {
  Map<String, String> env({
    String first = 'Herbert',
    String last = 'Poul',
    String email = 'someone@example.com',
    String phone = '+43 1 2345678',
  }) => {
    ReviewContact.firstNameVar: first,
    ReviewContact.lastNameVar: last,
    ReviewContact.emailVar: email,
    ReviewContact.phoneVar: phone,
  };

  Matcher throwsSaying(Object fragment) => throwsA(
    isA<AscApiException>().having((e) => e.toString(), 'message', fragment),
  );

  test('all four become the attributes Apple wants', () {
    final contact = ReviewContact.fromEnvironment(env())!;
    expect(contact.attributes, {
      'contactFirstName': 'Herbert',
      'contactLastName': 'Poul',
      'contactEmail': 'someone@example.com',
      'contactPhone': '+43 1 2345678',
    });
  });

  test('none set is null rather than an error', () {
    // A project that has not filled these in yet still gets to push a listing;
    // it is only the review detail that needs them.
    expect(ReviewContact.fromEnvironment(const {}), isNull);
  });

  test('half set is refused, naming what is missing', () {
    final partial = env()..remove(ReviewContact.phoneVar);
    expect(
      () => ReviewContact.fromEnvironment(partial),
      throwsSaying(contains(ReviewContact.phoneVar)),
    );
    // The reason it cannot simply send what it has: Apple refuses the write
    // after the rest of the listing has landed.
    expect(
      () => ReviewContact.fromEnvironment(partial),
      throwsSaying(contains('all four')),
    );
  });

  test('an empty value counts as missing, not as an answer', () {
    expect(
      () => ReviewContact.fromEnvironment(env(email: '   ')),
      throwsSaying(contains(ReviewContact.emailVar)),
    );
  });

  group('the phone number Apple will accept', () {
    // Apple's own wording when it refuses one: "Preface the phone number with
    // '+' followed by the country code". Checked here so it fails before the
    // push rather than in the middle of one.
    test('needs a leading + and a country code', () {
      for (final bad in [
        '01 2345678',
        '0043 1 2345678',
        '+',
        '+ 43',
        'call me',
      ]) {
        expect(
          () => ReviewContact.fromEnvironment(env(phone: bad)),
          throwsSaying(contains('country code')),
          reason: bad,
        );
      }
    });

    test('accepts the shapes people actually write', () {
      for (final good in [
        '+44 844 209 0611',
        '+4312345678',
        '+1 (555) 123-4567',
        '+43 1 234.5678',
      ]) {
        expect(
          ReviewContact.fromEnvironment(env(phone: good))!.phone,
          good,
          reason: good,
        );
      }
    });

    test('is trimmed, because a trailing newline is what a file gives you', () {
      expect(
        ReviewContact.fromEnvironment(env(phone: ' +4312345678\n'))!.phone,
        '+4312345678',
      );
    });
  });
}
