# Store image rules: what is refused, and on whose authority

Status: **implemented**, in `cux_ship_verify/lib/store_image.dart`. This is the
research and the decisions behind `imageEncodingProblem`, which both store trees
and the Play uploader call.

It exists because these are the checks most likely to be argued with. Each one
refuses a file somebody has committed, offline, on a claim about what a store
would do — and the first project that legitimately disagrees needs to find the
evidence rather than a number with no source. That is the same reason
`play_metadata.dart` labels its policy floor as this package's.

## What the stores actually publish

Read on **2 September 2026**, and quoted rather than paraphrased, because the
paraphrase is where a rule quietly grows.

[Play, *Add preview assets to showcase your app*](https://support.google.com/googleplay/android-developer/answer/9866151):

| Slot | Format, verbatim |
|---|---|
| App icon | *"32-bit PNG (with alpha)"*, 512x512 |
| Feature graphic | *"JPEG or 24-bit PNG (no alpha)"*, 1024x500 |
| TV banner | *"JPEG or 24-bit PNG (no alpha)"*, 1280x720 |
| Screenshots | *"JPEG or 24-bit PNG (no alpha)"*, min 320px, max 3840px |
| Wear OS / TV / Automotive screenshots | *"JPEG or 24-bit PNG (no alpha)"* |

[Apple, *Screenshot specifications*](https://developer.apple.com/help/app-store-connect/reference/screenshot-specifications/):
`.jpg`, `.jpeg` or `.png`; *"Images can't include alpha channels or
transparencies"*; per-device dimensions; **no colour space, no dpi and no bit
depth**.

Two things follow immediately, and both are load-bearing below.

**The app icon is the exception, in the opposite direction.** It is the one slot
in either store that *asks* for an alpha channel. A tree-wide "no image has
alpha" rule would refuse the icon Play requires — which is why the rule is
carried per slot, on `PlayImageSpec.imageRules`, rather than decided at the
call site.

**Apple publishes no bit depth at all.** Anything this package refuses on depth
for Apple is therefore this package's rule, and has to say so.

## Decision 1 — alpha is refused, per slot

Uncontroversial and already enforced on the App Store path since the tree was
first checked. The finding was that `checkPlayTree` called `readImageInfo`, used
`width` and `height`, and dropped the `hasAlpha` beside them — so a Play listing
with transparent screenshots passed every offline check and was refused during
ingestion.

The interesting half is that the capability was present and correct, and
enforced at one of the two places that needed it. That is what moved the rules
next to the parser: a third store path names whose rules it publishes under and
gets both checks, rather than remembering to write them out.

## Decision 2 — depth is refused above 8, not "not equal to 8"

Play asks for eight bits per channel by name: a 24-bit PNG is three 8-bit
channels, a 32-bit PNG four. A 16-bit-per-channel PNG is 48-bit, and every check
in this repository accepted one.

Apple was **observed** refusing one at ingestion: a consuming project's macOS
`--no-chrome` capture fallback writes depth 16, `screenshots flatten` preserved
it, and Apple refused the set after upload — so the remedy documented for one
failure produced a set the store rejects. That observation is the whole evidence
for the Apple half, and the message says so rather than implying Apple published
it.

**Below eight bits is deliberately not refused.** A greyscale or palettised PNG
carries a depth of 1, 2, 4 or 8 in its IHDR while its palette entries are eight
bits each — so "24-bit" is arguably what it already is. No store has been seen
to refuse one. Refusing it would be enforcing a rule with no failure under it,
which is the mistake the aspect-ratio note below exists to refuse to make.

## Decision 3 — the depth rule is PNG-only

Raised in review as "the check also refuses a 12-bit JPEG, with a message
glossing Play's *24-bit PNG* as though it covered JPEG". Researched, and it was
worse than a wording problem. The message produced for a 12-bit JPEG, run
through the real code path:

```
01.jpg is 12 bits per channel; Play takes 8 — "JPEG or 24-bit PNG (no alpha)",
which is 8 bits per channel.
  Reduce it, and change nothing else about the image:
    cux_ship screenshots flatten <path>
```

Wrong three times over:

1. **The Play citation does not cover the input.** In *"JPEG or 24-bit PNG (no
   alpha)"*, `24-bit` modifies the PNG, not the JPEG beside it — and `(no
   alpha)` likewise, JPEG having no alpha channel to speak of. Play states no
   JPEG bit depth anywhere. The gloss *"which is 8 bits per channel"* attributed
   to Play a rule Play does not state, which is exactly what `depthRule` being a
   quoted field is meant to prevent.
2. **The Apple citation is evidence about a different format.** It offers
   *"refuses a 16-bit **PNG** at ingestion"* as grounds for refusing a JPEG.
3. **The remedy cannot act on the file.** `flattenPng` calls `decodePng` and
   throws `not a readable PNG`; through the CLI it is quieter and worse, because
   `flatten_cli` walks `.png` — so `screenshots flatten` would skip the file,
   exit 0, and leave `verify` still refusing it. The user runs the remedy, sees
   success, and loops. That is the same shape as the greyscale-with-alpha gate
   found in the same review.

### Is a >8-bit JPEG even a thing

Legal, and essentially unproducible by accident:

- **SOF0 (baseline) is 8-bit by definition.** Every camera, screen capture and
  export writes SOF0.
- 12-bit is legal only under **SOF1** (extended sequential) or **SOF2**
  (progressive); the lossless **SOF3** allows 2 to 16, and is a DICOM
  medical-imaging format, not a screenshot.
- Reading one needs a libjpeg built `--with-12bit`, which **libjpeg-turbo — what
  Chrome, Skia and most of Android use — is not by default**. Browsers do not
  render it. libjpeg cannot support 8-bit and 12-bit simultaneously, because the
  bits per component is compiled in.

So a >8-bit JPEG has no observed store refusal, no working remedy in this
repository, and no pipeline that emits one. It is accepted, and
`ImageInfo.format` exists so the check can say which container it is looking at.

**`bitDepth` is still read and reported for a JPEG**, from the frame header's
sample precision. Reported rather than suppressed because the field is what the
file says, and a parser returning 8 for a 12-bit JPEG would be lying to whatever
asks next.

The counter-argument, recorded because it is not silly: a 12-bit JPEG genuinely
would fail in a store pipeline that cannot decode it. If somebody ever produces
one and a store refuses it, the check comes back — with a message citing *that*,
and a remedy that re-exports as baseline JPEG rather than naming a PNG tool.

## What is deliberately not checked

**Aspect ratio.** Play's page also says the maximum dimension *"can't be more
than twice as long as the minimum"*. Not enforced, and the reasoning is in
`play_metadata.dart`'s header: real listings carry 1080x2400 (2.22:1) and
1080x2424 (2.244:1) today, and 20:9 is the ordinary shape of every phone sold.
The reductio needs no counterexample at all — Play *mandates* a 1024x500 feature
graphic, which is 2.048:1, so a max-to-min rule applied to images declares Play's
own required size invalid.

It stays out until somebody produces a listing the store actually refused. That
sentence is the evidence bar the depth rule had to clear and the JPEG half of it
did not.

## Where the two halves of `screenshots flatten` sit

`flatten` removes alpha and reduces depth; it is PNG-only, by construction and
by intent. So it is the remedy named for a PNG refusal and never for a JPEG one.
Two defects have now come from that boundary being implicit — the
`numChannels < 4` gate that called colour type 4 opaque, and the depth message
above — which is why the check knows the format rather than inferring it.
