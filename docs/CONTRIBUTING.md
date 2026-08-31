# Contributing

Four rules, and a rule about the rules.

## The rule about the rules

**A rule lives here only while it cannot be a check, and only after it has
bitten twice.** Once is an accident; twice is a pattern; a hypothetical is
neither. And the moment somebody turns one of these into a test or a script
guard, it leaves this file — an enforced rule needs no reader. That is why
this file is short and should stay short: the README command map is *not*
listed here, because its twice-missed entries (#17, #22) are now held by
`test/readme_command_map_test.dart`, and the `## Unreleased` rename is held by
`tool/release.sh`. The best contribution to this document is a deletion.

Rules about *code* stay in the code, as comments beside what they govern, and
in `docs/design/` — a copy here would drift from the original. What earns a
place below is cross-cutting: true of every test and no particular one.

## A claim about both stores is checked against both

**A sentence asserting what "the stores" do — or what an unqualified
`promote`, `upload` or `--dry-run` does — is verified against both
implementations, or split into one statement per store.** The CLI is
deliberately symmetric and the stores are not: Play has an edit transaction and
commits atomically, the App Store has none and every write lands as it is made;
a Play promotion is public immediately, an App Store promotion goes to review
and then waits on `releaseType`; Play normalises unset options to defaults, the
App Store side leaves remote state alone. A claim written about the shared verb
is therefore written in whichever store the author had in mind, and is false
about the other.

Twice, in one bullet list. *"`play promote` and `appstore promote` are public
immediately"* was true of Play only, in the section headed **What cannot be
undone**. *"`--dry-run` ... opens a real store edit ... deletes the edit"* was
true of Play only, and the App Store has no edit to open. Both sat in the
safety section, and both survived because the sentence read as being about the
tool rather than about a store.

This cannot be a check — prose claims have no mechanical oracle — which is why
it is here rather than in a test. The fix each time was to split the sentence,
and the split is the shape to reach for.

## Watch the test fail

**Every guard's test is observed failing with the guard removed, before the
fix is trusted.** A test written after the fix and only ever seen green proves
nothing about the fix — it may pass for a reason unrelated to the guard, or
assert something the mutation cannot reach. Revert the fix, run the test,
watch it fail for the stated reason, restore.

**And list the mutations in the PR body**, because the body is the only
place the discipline is reviewable: a rule practiced invisibly is
indistinguishable from one not practiced, which is one step from the state
this file exists to prevent (#17 listed its twenty-two; #22 ran its
mutations and listed none, and review could not tell the difference). A
reviewer repeating one at random is normal and has caught real gaps.

## A fake must carry the semantics the tested branch selects on

**A fake that ignores the filter cannot reach the branch the filter selects.**
The first fake client here ignored `query`, so the 404 path of a
name-filtered lookup was unreachable from every test — a lookup for an absent
name came back full, and the suite could not have caught a dropped or
misspelled filter that would fail every real run (#17, found in review; #22
wrote its fake filtering server-side for exactly that reason, independently).
The general form: whatever the real endpoint does that the tested branch
*depends on* — filtering, a required parameter, an error shape — the fake
does too, with a comment saying which behavior it is carrying and why.

## A failure path needs its own failure injection

**A `catch` unreachable from every test rots.** The branch that exists for
the transient case is exercised by no happy-path test by construction, so it
gets its own injection, shaped like the real failure: when the enrichment
call and the primary call go to the same endpoint, the fake fails *only* the
enrichment (#22's `failUnfiltered` — the unfiltered listing throws while the
filtered lookup still works, which is the shape a transient failure actually
has). An injection that fails both calls tests a different, easier claim.
