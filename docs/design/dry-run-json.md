# Judging the listing without reading prose: `--json` on `upload --dry-run` and on `verify`

Status: **proposed**. Nothing here is built. Two commands, argued in one
document because they answer halves of a single question a consumer is asking
today and cannot get an answer to.

**Reviewed by that consumer before any of it was typed**, which is the process
`preview-wait-split.md` established and which paid again: they took three
proposals unchanged, improved the reasoning behind two of those, added two
fields this document did not have, and renamed the kind. Their additions are
marked where they land.

Asked for by the first consumer, ranked by their owner ahead of the preview
work that had already been written: *"those two are what let `ready` stop
declining to judge whether the published listing still matches the tree, which
is the single thing that command currently says it cannot do."*

## The question, and why prose cannot answer it

`tool/train.sh ready` answers *"can production run, and is the store showing the
repo's listing?"* It answers the first half and **declines the second**,
printing "not covered" and a command for a human to run. That command is
`cux_ship appstore upload --metadata … --dry-run`, whose answer is a stream of
`would update: en-US: description, keywords` lines.

**Reading those lines with a regular expression is the thing this package
exists to stop people doing.** `json-output.md` was written after a consumer's
status escaped from four expressions matched against stdout; `appstore
wait-previews` got an exit code rather than a phrase for the same reason. A
readiness check that greps a dry run is the same defect one layer out, and the
consumer knows it — which is why they asked rather than wrote the regex.

## The good news, and it changes the size of this

**The comparison already exists, is per-field, and is thrown away as prose.**

- `versionLevelChanges` compares the version-scoped half of the tree against
  what Apple holds and returns `copyright`, `reviewDetails`, and a
  locale-to-changed-attributes map. Its doc comment says why it is pure: *"a
  comparison that is wrong in one field skips a write and reports success,
  which is the quietest way this package can fail."*
- `appLevelChanges` does the same for the app-scoped half — categories, app
  info localizations, age rating, content rights.
- Assets have their own: `previewPlan` returns `unchanged` / `retime` /
  `replace`, and screenshots have the unchanged-file skip.

So `upload --metadata --dry-run` is **already a diff**, not a list of writes it
would make regardless. A caller reading its prose is reading the output of a
computation this package performs correctly and then flattens.

**That makes this the same shape as `userFraction`**, which `rollout-state.md`
argued in these terms: *"the question is not 'should this tool grow a rollout
report'. It is 'should the document it already prints stop being silently
incomplete about the record it is a document of'."* Here it is one step
stronger — the value is not merely read and dropped, it is *computed* and
dropped.

**This was nearly written up backwards.** A first reading of
`writeVersionLocalization` found an unconditional `PATCH` and concluded the
dry run says "would update" whether or not anything differs — which would have
made `--json` a machine-readable version of a useless answer, and the real work
a comparison that did not exist. The method is unconditional; its *caller*
passes only the attributes that differ. Recorded because the wrong version of
this paragraph would have justified a much larger change.

## Proposed: `upload --dry-run --json`

**`--json` only with `--dry-run`, and refused without it.** Every other `--json`
command in this package is a read. An `upload` that writes is not, and a
document describing writes that already happened is a different artifact with
different failure modes — it would have to say what *did* happen, including
partially. `--dry-run` makes the command a read in effect: it writes nothing,
and the document describes an intention. Pairing them keeps the invariant that
`--json` means "stdout is a document about state I did not change".

**Refused, not inert, and this repository already has the precedent.**
`--data-safety` is gone from `play upload` and gone *loudly* — still declared,
hidden, so passing it is refused with a message naming the command that took
over rather than a parser's "no such option". The consumer put the case for
that better than the alternative deserves: a flag that is accepted and does
nothing is a promise the caller cannot check. They have the scar from the other
direction — `--delete-conflicting-outputs` has been ignored by build_runner
since 2.7.0, and because it neither errors nor acts, people on that project
believed for a long time that it was the difference between a passing and a
failing run. **That is the real cost of an inert flag: not that it does nothing,
but that a theory grows around it.**

The refusal is offline and cheap, and it belongs beside the existing
`--skip-waiting` + `--beta-group` one.

```
cux_ship appstore upload --bundle-id … --version-name … \
  --metadata store/appstore/ios --dry-run --json
```

### The document

`kind: appstore.listing-diff`, and the shape follows the comparison rather than
the command.

**Not `appstore.dry-run`, which was the first name and names the *mode*.** Every
other kind here — `appstore.builds`, `appstore.versions`, `appstore.previews`,
`play.tracks` — names the thing being described. Spending `dry-run` on this one
would leave the next command to grow a dry run without it, and a `kind` is
permanent in a way a flag is not: it accrues a schema counter with history.
Raised by the consumer, and cheap now in a way it would not have been later.

| | |
|---|---|
| `matches` | **the answer**: true when nothing would change |
| `version` | the version name, and whether it would be created |
| `changes` | per scope — `version`, `app`, `assets` — what differs |
| `apple_only` | locales and fields Apple holds that the tree never mentions |
| `display` | the prose the command prints, for a renderer |

`matches` is the field `ready` reads and the reason the document exists. It is
this package's own opinion, so it sits in a field of its own beside the detail
rather than being derived by the caller — the same split `done` takes in
`appstore.previews` and `serving` in `play.tracks`.

**Per-field, not per-locale.** `changes.version.localizations` is
locale-to-list-of-attribute-names, because that is what the comparison
produces and because "en-US differs" sends somebody to diff four fields by
hand. Names, not values: the tree is on disk and the store is one read away,
and a document carrying both copies of every string is a document nobody will
read.

### What it must not claim, and how `apple_only` stops it

**`matches: true` is not "the store page is correct".** It means every field
this repository *declares* agrees with Apple. A field the tree does not name is
not compared, because "present means owned" is the tree's rule everywhere else
— so a description edited in App Store Connect, in a locale the tree does not
carry, is invisible to this and correctly so. The doc comment has to say it,
for the reason `serving`'s did not and was wrong twice.

**And a doc comment is not enough, which is the consumer's correction.**
`matches: true` while Apple holds a `de-DE` localization the tree never mentions
is *true*, and reads as *the store page is what we think it is*. That is
`LIVE (173)` in a new place: a correct statement whose reader draws a stronger
conclusion, with nothing in the document to stop them.

`apple_only` is that thing made visible rather than merely unclaimed — the
locales, and any app-level field, that Apple holds and the tree does not
mention. **It deliberately does not make `matches` false**: "present means
owned" is right and weakening it would make every consumer of a partial tree
report a permanent mismatch. The narrow claim stays narrow, and what it excludes
is in the document beside it.

The alternative was a sentence in the consumer's own output naming the gap, and
it is worse for a reason worth recording: **the sentence is there whether or not
the case is live**, so it is either always printed and therefore ignored, or
conditional on a check the consumer would have to write against data this
document declined to give it.

**This is the fourth instance of one shape.** `ROLLED OUT` rather than `LIVE`,
because Play's API describes the rollout and cannot see the review. `serving`'s
wording, twice. The consumer's `--prepare` note labelling *Pending Developer
Release* as an inference nobody has watched. And now `matches`. Each time the
tool can assert something narrower than the reader wants to hear, and each time
the fix is the same: say the narrow thing in the tool's own voice, and make the
excluded part visible rather than leaving the reader to assume it away.

## Proposed: `verify --json`

Simpler, and the smaller half. `verify` already prints two things a document
wants: the `checked …` lines naming every artifact it inspected, and the
problems. The first exists because *"a clean run used to print one line, so a
reader could not tell whether the data safety declaration had been validated or
silently skipped"* — which is exactly the property a document must preserve
rather than flatten to a boolean.

`kind: verify`, carrying `ok`, `checked` (what was inspected, by kind and
path), **`skipped`** (`{what, why}` per entry), `problems` (each as a string,
since they are written for a person), and `display`.

**`checked` is not decoration.** A caller that reads `ok: true` without it has
learned nothing about *coverage*, which is the failure the prose version was
changed to close. A document that dropped it would reintroduce the defect in a
format that makes it harder to notice.

**`skipped` is the consumer's addition, and it closes the half `checked` leaves
open.** With `checked` alone, a reader notices an omission only by already
knowing the full expected set — so a check that silently did not run is
invisible unless somebody is holding the list in their head. That is the
data-safety failure `checked` was built to prevent, moved one level up. Their
sentence for it is the one to keep: *absence stops being inferred from what is
not in a list, which is a thing nobody does reliably.*

So the two fields are not a list and its complement for symmetry's sake. One
says what was covered; the other says what was not, and why, without the reader
having to derive it.

## Open: are the two problems lists the same list

Status: **open**.

`verify`'s problems are strings written for a person. A consumer branching on
them wants structure — which check, which file, which locale. Giving them
structure now is speculative, and giving them strings makes a later change a
schema bump.

**Not blocking, and the reason is the consumer's own ordering:** they want to
know *whether* the inputs are publishable, and to show a human the problems if
not. Nobody has asked to branch on a problem's identity. Strings with a
`display` beside them answer today's question and leave the structured version
as an addition rather than a replacement.

## Deliberately not proposed

**`--json` on a real `upload`.** See the refusal above. If somebody wants a
receipt of what a publish did, that is a different document — it has to
describe partial success, which an intention never does.

**A `--check` exit code, like `flatten --check`'s 2.** Tempting, and wrong for
the same reason 4 was not allowed to be reused: `matches: false` is not a
failure and not "work to do this command can perform" — it is an answer. The
caller decides what it means. Exit 0 with `matches: false` is the honest shape,
and `README.md`'s exit-code table now says why a new number is not free.

**The consumer's reason is better than that one and is the one to keep: it is
about where truth lives.** If the exit code also carried the answer, a caller
would have two sources for one fact, free to disagree, and would have to decide
which wins. One source is worth more than the convenience of branching without
parsing — and that argument survives contact with a maintainer who later wants
to be helpful by adding the code.

The cost is concrete rather than theoretical, in their runner: it throws on any
non-zero unless the call site opts out, and its document reader throws *before*
parsing, deliberately, because a failure leaves stdout empty. A non-zero
`matches: false` would send the **ordinary** case down the failure path, and be
unwound at the one place designed to stop exactly that.

**And `flatten --check` is genuinely different, which is worth stating so the
precedent is not misread.** That command has no document, so its exit code is
the only channel it has. This one has a document. The answer goes in it.
