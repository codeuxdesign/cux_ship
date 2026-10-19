# Creative assets: the header and the search results image

Status: **built**, in `cux_ship_verify/lib/metadata.dart` (the tree and the
offline checks) and `cux_ship/lib/src/appstore/creative_assets.dart` (the
`appstore creative-assets` command). Images only; several sections below are
`open` and carry their own status.

App Store Connect started accepting two new optional assets on 5 October 2026,
shown on iOS 27 / iPadOS 27 and later: a **product page header** and a **search
results** image or video. This document records what Apple publishes about
them, which of this package's choices rest on that and which rest on
inference, and what is still open. The split matters more here than for
screenshots: the API is three weeks old, third-party write-ups appeared before
Apple's articles, and documented behavior is the only kind there is yet.

## Sources, and how they were read

Read on **19 October 2026**. The documentation pages were fetched through their
`/tutorials/data/documentation/…json` form, which returns the article text the
JavaScript site renders.

| | |
|---|---|
| **[S]** | Apple's OpenAPI specification, [app-store-connect-openapi-specification.zip](https://developer.apple.com/sample-code/app-store-connect/app-store-connect-openapi-specification.zip). `info.version` **4.5.1**, `openapi.oas.json` dated 2026-10-06, zip sha256 `7b826ae9ca3e45b0e7df2643cbb811c9930632640944db11a8af4586fab9db46` |
| **[RN]** | [App Store Connect API 4.5.1 release notes](https://developer.apple.com/documentation/appstoreconnectapi/app-store-connect-api-4-5-1-release-notes) |
| **[U]** | [Understanding the App Asset Library](https://developer.apple.com/documentation/appstoreconnectapi/understanding-the-app-asset-library) |
| **[IMG]** | [Uploading and managing image assets](https://developer.apple.com/documentation/appstoreconnectapi/uploading-and-managing-image-assets) |
| **[PL]** | [Placing assets on your App Store surfaces](https://developer.apple.com/documentation/appstoreconnectapi/placing-assets-on-your-app-store-surfaces) |
| **[SPEC]** | [Discovering asset specifications](https://developer.apple.com/documentation/appstoreconnectapi/discovering-asset-specifications) |
| **[MIG]** | [Migrating to the App Asset Library](https://developer.apple.com/documentation/appstoreconnectapi/migrating-to-the-app-asset-library) |
| **[H-SPECS]** | [Creative assets specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/creative-assets-specifications) |
| **[H-MANAGE]** | [Manage your App Store assets](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-your-app-store-assets) |
| **[H-SUBMIT]** | [Submit assets from Asset Library](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-assets-from-asset-library) |

## What was confirmed, and what was not

Three claims came from third-party write-ups and were the reason this research
happened. All three hold, with one difference in the third.

| Claim | Verdict | Where |
|---|---|---|
| There is an "App Asset Library" API | **Confirmed.** `appAssetLibraries`, `appAssetLibraryImages`, `appAssetLibraryVideos`, `appAssetLibraryPlacements`, `appAssetLibraryRefData` | [S], [RN], [U] |
| Assets go through App Review on their own, independent of a version | **Confirmed** in the Help pages: *"You can submit creative assets as a standalone submission through Asset Library … without updating your app's version"*. In the spec, `reviewSubmissionItems` gained `appAssetLibraryImage` and `appAssetLibraryVideo` | [H-MANAGE], [H-SUBMIT], [S] |
| A "use header asset in search results" option exists | **Confirmed in the console, absent from the API.** No attribute anywhere in [S]. The API's equivalent is one universal image with a placement per type | [H-MANAGE], [SPEC] |

What the implementation rests on, claim by claim:

| What the code does | Basis |
|---|---|
| `GET /v1/apps/{id}/assetLibrary`, one library per app | **Confirmed**: [S], [U] |
| Reserve with `category: CREATIVE_ASSETS`, `fileName`, `fileSize`, `referenceName`, relationship `assetLibrary` | **Confirmed**: [S] `AppAssetLibraryImageCreateRequest` |
| PUT each `uploadOperations` part, then `PATCH {uploaded: true}`, **no checksum** | **Confirmed**: [IMG] — *"there's no `sourceFileChecksum` attribute to send"* |
| Poll `state` until it leaves `AWAITING_UPLOAD` / `UPLOAD_COMPLETE`; `FAILED` carries `stateDetails` | **Confirmed**: [S] `AppAssetLibraryAssetState`, [IMG] |
| Delete a `FAILED` copy and reserve again | **Confirmed**: [IMG] |
| `COMPLETE` counts as usable | **Inferred.** The spec maps it; no article describes it |
| Skip identical bytes by an MD5 in `referenceName` | **This package's convention.** Apple exposes no checksum; [MIG] says to *"record the returned asset ID against your own identifier"* and does not say where |
| Placement: `placementType` plus `image` and `appStoreVersionLocalization` | **Confirmed**: [S] `AppAssetLibraryPlacementCreateRequest` |
| `PRODUCT_PAGE_HEADER_ASSET`, `APP_STORE_SEARCH_RESULTS_ASSET` | **Confirmed**: [S] `AppAssetLibraryPlacementType` |
| Universal = one image, two placements | **Inferred** from [SPEC]: a universal spec *"satisfies several placement types at once"* by *"creating a placement per type"*. No article shows the header-and-search pair specifically |
| Placements cannot be edited; delete and recreate | **Confirmed**: [S] has no PATCH; [PL] *"You can't change a placement after you create it"* |
| Placing only on an editable version | **Confirmed**: [PL], `409 STATE_ERROR.INVALID_STATE` on an approved parent |
| Omitting `placementGroup` on create | **Inferred.** It is nullable and not required by any `anyOf` branch; its values come from the reference data, which needs credentials and was not read |
| Standalone submission: `reviewSubmissions` → `reviewSubmissionItems` with `appAssetLibraryImage` → `submitted: true` | **Inferred sequence.** Each piece is in [S], and the three steps are the ones a version submission takes. No Apple article walks through it for an asset, and the API articles describe only review through the parent surface ([PL]: *"Placements go through App Review as part of their parent surface"*) |

**Nothing here has run against App Store Connect yet.** The tests run against a
fake that implements the spec's filters. The first real run should be
`--dry-run`, then a library-only upload with no `--version-name`, before
anything is placed or submitted.

## The tree

```
listings/<locale>/creative_assets/UNIVERSAL/<one image>
listings/<locale>/creative_assets/PRODUCT_PAGE_HEADER_ASSET/<one image>
listings/<locale>/creative_assets/APP_STORE_SEARCH_RESULTS_ASSET/<one image>
```

**Directory names are Apple's placement types**, the convention `screenshots/`
and `previews/` follow, so a typo fails a lookup rather than uploading
somewhere unintended. `UNIVERSAL` is the exception and the only name that is
this package's: Apple has no placement by that name. In Apple's model,
"universal" is a property of a specification (`universalAsset: true`). The
directory names the outcome, and the uploader turns it into two placements.

**Per locale, because placements are.** The image is app-wide and can be
reused across locales, but a placement joins it to one
`appStoreVersionLocalization`. So the tree holds a file per locale, and the
uploader deduplicates identical bytes.

**One image per slot.** [SPEC] and [PL] give "1 product page header asset per
group" for App Store versions. Apple gives no count for search results, and
one is what the console offers.

**`UNIVERSAL` beside a dedicated slot is refused.** It would ask for two images
in one placement. A universal-size header with a dedicated search image is
expressed by putting the 5244×2950 PNG in `PRODUCT_PAGE_HEADER_ASSET/`, which
accepts it, because [H-SPECS] lists a universal row under each placement.

## The checks

From [H-SPECS], verbatim where quoted:

| Slot | Size | Format |
|---|---|---|
| Universal | 5244×2950 (16:9) | PNG only |
| Header | 3840×1646 (21:9), or the universal size | JPEG or PNG (universal: PNG) |
| Search results | 3:2, 1920×1280 to 3840×2560, or the universal size | JPEG or PNG (universal: PNG) |

*"Images can't include alpha channels or transparencies"* — the same sentence
the screenshot page uses, so the same alpha check applies.

**The nominal ratios are not exact.** 5244×2950 is 1.7776, not 1.7778, and
3840×1646 is 2.3329, not 2.3333. Applied exactly, 16:9 and 21:9 would refuse
the sizes Apple publishes, so exact sizes are checked as sizes. The ratio is
checked only across the search slot's range.

**The extension has to agree with the bytes.** Apple's specifications list
extensions and MIME types side by side, and the universal size is PNG only.

**Bit depth is not checked.** Apple publishes none for these assets. The 16-bit
refusal behind the screenshot rule (`store-image-rules.md`) was observed on a
screenshot set, and enforcing it here would be a rule with no failure under
it. `StoreImageRules.checksDepth` carries the decision.

## Open: the search slot's ratio tolerance

Status: **open**.

The check refuses anything that is not *exactly* 3:2, such as 2000×1333.
Apple's reference data carries an `aspectRatio` string and min/max dimensions,
and how strictly Apple compares them is unknown. Exact is the safe direction
— every exact 3:2 size in the range is easy to produce — and it would be wrong
only by refusing a file Apple accepts. Reading `appAssetLibraryRefData` with
credentials would settle it.

## Open: videos

Status: **open**.

Apple takes a video in both placements: header 21:9, search results 3:2, 5 to
30 seconds, 30 or 60 fps, `.mov`, `.m4v` or `.mp4`, muted by default and
looping ([H-SPECS]). The spec's `appAssetLibraryVideos` mirrors the image
resource with `previewFrameTimeCode` added. [H-SPECS] has no universal video
row and no file size, codec or audio rule, so those would have to come from
the reference data. A video in a slot directory is refused, never skipped, so
adding support is new acceptance rather than a change of meaning.

## Open: a live version has no API way to switch assets

Status: **open**.

[H-MANAGE]: a version that is already live can switch to an approved asset
with **Publish** in the console, with no new version. Nothing in [S]
corresponds to it, and a placement on an approved parent returns 409. So on a
live app this command can upload, and submit standalone with
`--submit-for-review`. Putting the approved asset on the live page is a click
in App Store Connect, until an endpoint appears.

## Open: locale fallback

Status: **open**.

Whether a locale with no header or search placement falls back to the primary
locale's is not stated on any page read. A tree that carries one locale's
assets and not another's leaves the other alone. That is *present means
owned*, and it is the only behavior this package can promise without knowing
the fallback.

## Open: whether a placement's image relationship carries data

Status: **open**.

The idempotency of a placement does not depend on it. `place` asks Apple with
`filter[placementType]` and `filter[image]`, which Apple answers whatever shape
the response has. It would matter only if reading back *which* image is placed
were wanted for a report. `appStoreVersions` returns a relationship without
`data` unless `include` asks for it ([rollout-state.md](rollout-state.md)), and
nobody has looked at a placement yet.
