# Contributing

Three rules, and a rule about the rules.

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
