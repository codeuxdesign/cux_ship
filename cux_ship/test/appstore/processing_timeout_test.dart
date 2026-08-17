// SPDX-License-Identifier: Apache-2.0
//
// What a build that never became visible says for itself.
//
// **The message is the whole feature**, which is why it is pinned here. This
// exception replaced an `AscApiException(504)` — a gateway error Apple never
// sent, for a timeout that is entirely ours — whose advice was "it is not lost,
// re-run". That is right for a slow build and exactly wrong for a rejected one,
// and a rejected build is the common cause of one that never appears. Apple
// reports those only by e-mail and in Activity, never through the API, so a
// message that does not say where to look sends the reader round the same
// forty-five minutes again.
import 'package:cux_ship/src/appstore/app_store.dart';
import 'package:test/test.dart';

void main() {
  test('a build that never appeared points at the e-mail', () {
    final message = ProcessingTimeout(
      buildNumber: '33',
      waited: const Duration(minutes: 45),
    ).toString();

    expect(message, contains('33'));
    expect(message, contains('45 minutes'));
    // The two things a reader has to come away with.
    expect(message, contains('e-mail'));
    expect(message, contains('Activity'));
  });

  test('a null state reads as "not visible", which is the rejected shape', () {
    // **Load-bearing, and the kind of distinction a later refactor flattens.**
    // A build Apple is still working on has a state; a build that was refused
    // during processing has none at all, because there is no build. Collapsing
    // null to an empty string would leave the sentence saying "was still after
    // 45 minutes" and lose the only clue that it was never there.
    final absent = ProcessingTimeout(
      buildNumber: '33',
      waited: const Duration(minutes: 45),
    ).toString();
    expect(absent, contains('still not visible after'));

    final known = ProcessingTimeout(
      buildNumber: '33',
      waited: const Duration(minutes: 45),
      lastState: 'PROCESSING',
    ).toString();
    expect(known, contains('still PROCESSING after'));
    expect(known, isNot(contains('not visible')));
  });

  test('re-running is offered as the slow case, not the only case', () {
    // The old advice led with this and it is the wrong half to lead with: no
    // number of re-runs makes a refused build appear.
    final message = ProcessingTimeout(
      buildNumber: '33',
      waited: const Duration(minutes: 45),
    ).toString();
    expect(
      message.indexOf('e-mail'),
      lessThan(message.indexOf('re-running')),
      reason: 'the e-mail has to be read before a re-run is worth trying',
    );
  });
}
