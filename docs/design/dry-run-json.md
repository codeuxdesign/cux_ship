# Judging the listing without reading prose: `--json` on `upload --dry-run` and on `verify`

Status: **proposed**. Nothing here is built. Two commands, argued in one
document because they answer halves of a single question a consumer is asking
today and cannot get an answer to.

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

The refusal is offline and cheap, and it belongs beside the existing
`--skip-waiting` + `--beta-group` one.

```
cux_ship appstore upload --bundle-id … --version-name … \
  --metadata store/appstore/ios --dry-run --json
```

### The document

`kind: appstore.dry-run`, and the shape follows the comparison rather than the
command:

| | |
|---|---|
| `matches` | **the answer**: true when nothing would change |
| `version` | the version name, and whether it would be created |
| `changes` | per scope — `version`, `app`, `assets` — what differs |
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

### What it must not claim

**`matches: true` is not "the store page is correct".** It means every field
this repository *declares* agrees with Apple. A field the tree does not name is
not compared, because "present means owned" is the tree's rule everywhere else
— so a description edited in App Store Connect, in a locale the tree does not
carry, is invisible to this and correctly so. The doc comment has to say it,
for the reason `serving`'s did not and was wrong twice.

## Proposed: `verify --json`

Simpler, and the smaller half. `verify` already prints two things a document
wants: the `checked …` lines naming every artifact it inspected, and the
problems. The first exists because *"a clean run used to print one line, so a
reader could not tell whether the data safety declaration had been validated or
silently skipped"* — which is exactly the property a document must preserve
rather than flatten to a boolean.

`kind: verify`, carrying `ok`, `checked` (what was inspected, by kind and
path), `problems` (each as a string, since they are written for a person), and
`display`.

**`checked` is not decoration.** A caller that reads `ok: true` without it has
learned nothing about *coverage*, which is the failure the prose version was
changed to close. A document that dropped it would reintroduce the defect in a
format that makes it harder to notice.

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
