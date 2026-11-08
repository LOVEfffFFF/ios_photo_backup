# Original edit timestamp experiments (0.2.5)

The 0.2.4 device test directly exported both actual plist resources on iPhone 14 Pro Max / iOS 17.7.2. DNG, render and compressed recipe bytes matched. Only `adjustmentTimestamp` changed from edit time to capture time. Normal restore still uses the verified 0.2.4 path; this build adds controlled experiments, not a confirmed fix.

Each experiment creates at most one new copy of a phone-selected, backed-up, edited still image. It uses verified downloads, journals the new copy ID and reads its actual resources and complete edit envelope. No original asset is changed, no source/backup bytes are rewritten, and copies are not automatically deleted. All variants share the session's existing ten-attempt limit. Unknown variants and variants sent to inspection or an older phone build are rejected.

| `importVariant` | Variable tested |
| --- | --- |
| `baseline` | Existing public resource import |
| `fileDates` | Unique disposable copies: original file creation/modification date set to capture time; edit/render files to the original plist edit time. File contents stay unchanged. |
| `adjustmentData` | Public `addResource(with:data:options:)` overload for the edit envelope |
| `resourceImportDate` | Runtime `setAlternateImportImageDate:` on extra resource options, set to the original edit time |
| `requestImportDate` | Runtime `setAlternateImportImageDate:` on the new asset creation request |
| `requestModificationDate` | Runtime `setModificationDate:` on the new asset creation request |
| `combinedDates` | Both runtime import-date settings plus the request modification date |

The last four variants use undocumented Photos setters observed in published iOS 17 runtime headers, not Apple-supported APIs. They are isolated to explicit live-debug experiments; normal restore and baseline verification never call them. Setter availability is checked before creation. Availability alone does not establish that a setter is authorized, effective, stable, or suitable for an App Store build. A runtime error must remain a failure; never silently fall back and report a timestamp fix.

References used only as investigation clues:

- https://github.com/MTACS/iOS-17-Runtime-Headers/blob/main/Frameworks/Photos.framework/PHAssetResourceCreationOptions.h
- https://github.com/MTACS/iOS-17-Runtime-Headers/blob/main/Frameworks/Photos.framework/PHAssetChangeRequest.h
- https://developer.apple.com/documentation/photos/phassetcreationrequest
- https://developer.apple.com/documentation/photos/phassetresourcecreationoptions

After installing 0.2.5 and selecting the same sample in live debug, the local controller can issue:

```text
node debug-bridge/control.cjs CONNECTION_FILE roundTrip asset-1 fileDates
node debug-bridge/control.cjs CONNECTION_FILE roundTrip asset-1 resourceImportDate
```

Run one at a time; check its result before considering another. Prioritize public variants and stop when a reliable candidate is found. Transport `ok` does not imply recovery passed. Independently decode `originalEditing.raw.currentAdjustmentEnvelope.resourceData` and `copies[].editing.raw.currentAdjustmentEnvelope.resourceData`, check lengths/hashes, and compare entire actual plist bytes. Confirm original edit time, exact original DNG/render/payload, capture date and original asset existence. Do not accept changing the capture date, editing the original DNG metadata, replacing the backup timestamp, or omitting the render as a solution.

If a variant succeeds, independently inspect its copy, then verify repeatability and system Photos RAW/revert/re-edit behavior before promoting any fix. This build's request modification-date variant uses the plist's original whole-second edit time; it does not promise preservation of the asset database's separate fractional `modificationDate`.

## Completed device experiments, 2026-10-19

All six variants ran once on the user-selected edited ProRAW sample using 0.2.5 on iPhone 14 Pro Max / iOS 17.7.2. No timestamp-preserving candidate passed. Five copies were created; originals and test copies were retained.

| Variant | Observed result |
| --- | --- |
| `fileDates` | Filesystem date changes did not preserve the actual plist edit timestamp. |
| `adjustmentData` | Photos rejected the data overload with `PHPhotosErrorDomain 3300`; no copy created. |
| `resourceImportDate` | Date on the extra resource options did not preserve the plist timestamp. The main photo resource options were not set by this variant. |
| `requestImportDate` | Date on the creation request did not preserve the plist timestamp. |
| `requestModificationDate` | Asset database modification date changed to the requested whole-second edit time; plist timestamp still changed to capture time. |
| `combinedDates` | Same split result: database modification date set, plist edit timestamp not preserved. |

For every successful import, actual full plist bytes were independently decoded and bound to the exported resource hash. Replacing only the original plist date with the restored date reproduced the entire restored XML byte for byte. Original DNG, render, compressed recipe and full inflated JSON matched; capture date was preserved. Transport completion was not treated as a successful recovery result.

A later, separate inspection of the `requestModificationDate` copy verified its actual plist bytes again and confirmed the database date persisted separately. This is evidence that the setter affected a different field, not a fix for original `adjustmentTimestamp`. Its requested date came from the whole-second plist date; original fractional database time was not restored.

Runtime header investigation found an internal `PFAssetAdjustments.adjustmentTimestamp` setter and a separate persisted adjustment relationship. These are clues about internal representation, not an available public PhotoKit timestamp setter or proof of the import implementation. No direct library database mutation was attempted. The reviewed public API documentation exposes capture date changes and resource copying, but no documented setter for the original edit timestamp. These experiments do not prove that every possible approach or iOS version fails. Raw device results, complete envelopes and identifiers remain outside Git.
