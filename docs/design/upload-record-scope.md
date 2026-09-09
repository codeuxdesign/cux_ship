# One upload record names a commit, not a store

Status: **open**, and possibly not worth closing. Recorded 21 August 2026 after
the first release that made the gap visible, so that the next person who notices
it finds the reasoning rather than repeating it.

## What happened

How It Went's build 69 went to three stores from one commit — Google Play
internal, TestFlight iOS, TestFlight macOS. One tag was written:

```
uploaded/v1.1.0+69 -> ca772bc
build 69 of 1.1.0
store: play
sha256 bb38aa0f8b398b4b9003248d3be40e1c88f62efce3d9f6a738168b5616cd0be1
```

`store: play` because Android uploaded first. iOS and macOS each found the tag
already at the right commit, reported `upload already recorded`, and carried on
— which is correct behavior and the reason the record is idempotent at all.

So the annotation named one of three stores and read as if it were the whole
truth. **The `store:` line has been removed**; the tag now claims exactly what it
can prove — this commit, this build number, these bytes, uploaded somewhere.

## Why not simply record all three

Because the tag is written *before* each store is contacted, and the second and
third uploads happen minutes or hours later, possibly on other machines. Adding
to the annotation means rewriting a published tag, which means `git tag -f` and a
**force-push**.

That is the one operation that makes a record stop being a record. Git does not
update a changed tag on an ordinary fetch, so every clone that already has it
keeps the old body: some machines say `play`, others `play, appstore`, and
nothing reconciles them. A record that can be rewritten is not evidence, and
evidence is the entire purpose.

## The shape that would work, if it is ever wanted

Per-store *names*, so each record is written once and never touched:

```
uploaded/v1.1.0+69/play
uploaded/v1.1.0+69/appstore
```

Immutable, additive, no force-push, and each carries its own store, timestamp and
digest honestly. The costs are real: three times the tags, a namespace change
that every consumer's tag globs must survive, and the collision check becomes
per-store rather than per-commit — which is a weaker guarantee, because "this
build number reached two different commits" is exactly what one shared name
catches.

## Why this is filed rather than built

**Nobody has asked what a record's store was.** The question the tag answers in
practice is "was this commit published, and as which build" — for finding a
commit that a `gc` would otherwise collect, and for refusing a build number that
has been used twice. Both are per-commit questions. The store is decoration on
the answer.

Build it when a real question needs it: a promotion script that must know
whether the App Store already has a build, an audit that must show which stores
carried a version. Until then the shared name is doing the job, and three tags
per upload to record something nothing reads is worse than one honest line
fewer.

**If you are here because you wanted the store back**, that is the signal this
document is waiting for — say what needed it, and take the per-store names.

## The question arrived, and the answer turned out not to be tags

Recorded 9 September 2026. A consumer's release train wanted exactly the
promotion script §"Why this is filed rather than built" names: *does the App
Store already hold this build?* Its `status` stage could only read the tag and
print a hedge — "a tag says a build was sent, not that a store took it" — and
the hedge was earning its keep, because the record said 168 while the App
Store's iOS platform held 166 and Play and macOS held 168.

**That is the reopening condition, and it still does not want per-store tags.**
The question is not *which store did this commit go to* — a fact about the
past, which a tag records. It is *what is each store serving now* — a fact
about the present, which a tag cannot record at any granularity, because it is
written before the store is contacted and never revised. Per-store names would
have turned one over-reporting record into four.

`read.dart` (4.1.0) answers it directly, per store and per Apple platform, from
the only authority there is. So the tag goes back to being one thing: **the
commit an artifact was built from**, which is a git fact no store knows and the
reason the record exists. `release-check.md` §1 had already written the
distinction down — *"git records what we sent; a store records what users can
get"* — and named the git-versus-store diff as the thing that catches the gap,
out of scope there and still not built. Half of it is now cheap: the store side
is a library call rather than four regular expressions over stdout.

**The consumer's hedge is the consumer's to remove**, and it is not a
workaround for a missing capability — it is a correct sentence about the wrong
oracle. Nothing in this package should print what a store holds without asking
one. `cux_ship/README.md`'s upload-record section now says so where the tag is
introduced, because that is where somebody decides what to read it as; a
consumer that finds this document has already gone further than most.

The door §"The shape that would work" holds open stays open on its original
condition — an *audit* asking which stores carried a version, which is a
question about the past and the one thing a store cannot answer about a build
it has since replaced. This was not that.
