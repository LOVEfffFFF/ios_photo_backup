# Community research and primary resource experiment

Research dates: 2026-10-19 to 2026-10-20. The six 0.2.5 device experiments and the 0.2.6 primary-resource import-date experiment fail preservation of the actual adjustment plist timestamp. This research has not found a verified solution for that exact iOS 17.7.2 import failure.

## Closely related timestamp report

[osxphotos issue 2158](https://github.com/RhetTbull/osxphotos/issues/2158) reports that the same edited resource exported from an iPhone using Share → All Photos Data / AirDrop and exported from a Mac using osxphotos has different `adjustmentTimestamp` values. The reporter subsequently suspected the iPhone value. The maintainer [confirmed](https://github.com/RhetTbull/osxphotos/issues/2158#issuecomment-4550633105) that osxphotos copies the actual library plist without reconstructing it, and their test matched the last adjustment time. The issue was closed after this clarification, not after an iOS timestamp-preserving import fix.

This is an export discrepancy involving a video and newer operating systems, not the same ProRAW restore reproduction. It suggests that comparing independent export paths could be useful; it does not prove our library's stored timestamp is identical to a generated PhotoKit export or prove the cause of our import discrepancy. Our original/copy comparison remains an observation through actual PhotoKit resource exports.

## Existing import approaches do not establish timestamp preservation

[osxphotos issue 1871](https://github.com/RhetTbull/osxphotos/issues/1871) and its comments discuss grouping the original, AAE and rendered file under Photos-compatible filenames for macOS Photos import. They report restored edits, not byte-exact plist timestamps, and use the Mac import route. They cannot establish an iOS-only fix.

The [photokit Python library at commit 62116c2](https://github.com/RhetTbull/photokit/blob/62116c2658081e5cf38ced01aabb67f57cb0f6e7/photokit/aae.py) parses AAE into a new `PHAdjustmentData`, replacing `com.apple.photo` with its own identifier because the editing submission is rejected otherwise. Its comments explicitly say Apple Photos cannot reopen those Apple adjustments. The parser does not pass the original `adjustmentTimestamp` to the edit object, and it also invokes undocumented render/base-version setters. This is not a suitable solution for preserving our already working Apple filter controls and original timestamp.

Apple now documents [PHAsset.adjustmentTimestamp](https://developer.apple.com/documentation/photos/phasset/adjustmenttimestamp), introduced in iOS 18 / macOS 15. It is read-only (`get`), not a timestamp setter. Its existence does not imply the iOS 17.7.2 device should be upgraded or that an upgrade fixes import.

Targeted GitHub issue searches, repository code and Stack Overflow searches did not yield a verified fix for the exact sample. Apple Developer Forums searches were blocked by browser verification; general search results were mostly irrelevant. The search was therefore incomplete and is not evidence of universal impossibility.

## Additional bounded experiment in 0.2.6

Code review identified an untested distinction: `resourceImportDate` in 0.2.5 sets `alternateImportImageDate` on the extra resources only. The primary `.photo` DNG still uses nil options. The request-level setter and filesystem dates do not establish the effect of a date on the primary resource's own creation options.

`mainResourceImportDate` tests only that primary resource option, set to the original plist edit date. Extra resource options and the original capture date stay as in baseline. This is an inference from the runtime resource-options interface and our import code, not a workaround demonstrated by an online report. It uses an undocumented selector and is restricted to live debug on a selected backed-up edited still image. The option's getter is checked before import; a missing selector or mismatched option value fails before creating an asset.

Only one new copy is needed for the initial experiment. Preserve input DNG/render/plist bytes, source and backup, capture date and all test copies. Actual full plist timestamps and hashes must pass independently after import; an option getter or transport success is not acceptance. If a candidate passes, independently re-read it and verify repeatability and system Photos RAW/revert/re-edit behavior before enabling it in normal restore. At initial preparation, the variant had not run on a device. The subsequent failure is recorded below. Normal restore never calls the diagnostic setter.

### Device connection update, 2026-10-20

The user installed and connected the verified 0.2.6 build, but selected a different RAW sample with a camera Effect recipe (`com.apple.photo/1.4`). Its actual plist edit timestamp equals the capture timestamp rounded down to seconds. This cannot discriminate timestamp preservation from the observed reset, and version 1.4 is outside the native experiment's supported 1.9.1 schema. No `mainResourceImportDate` job was submitted for it.

At the user's request, one ordinary baseline copy was created and independently inspected. DNG, rendered JPEG, current original/copy plist and full compressed/inflated Effect recipe agree. However, the backup's 880-byte current plist differs from the original/copy's 939-byte plist solely by an added `adjustmentRenderTypes=3072` field; the backup's current plist equals its camera AAE. The source of that export-time difference is not established. The camera AAE was not imported, current-version filter naming remains unsupported for this sample, and Photos UI acceptance is pending. Strict restore remains unconfirmed, and this is not a successful timestamp experiment. See [0.2.6 device validation](VALIDATION-0.2.6.md).

The user then saved a 50% Effect edit on that baseline copy, backed it up and selected both sources. The new current recipe is `com.apple.photo/1.9.1` and its actual edit time differs from capture time. One `mainResourceImportDate` trial failed: its exported plist edit time changed from 06:39:47 to 06:28:05 Beijing, matching capture time rounded down to seconds. Independent inspection confirmed the same full plist and timestamp. The full plist differs only by that date; DNG, current rendered JPEG, complete compressed/inflated recipe and fractional capture date match, and both source photos remain unchanged. This is an actual failed trial, not a preflight failure or a name-parser-only rejection.

## Implementation clues for a separate 0.2.7 experiment

The pinned third-party [iOS 17.6.1 PHAssetCreationRequest decompilation](https://github.com/SuperChaoM/iPhone15-3_17.6.1_21G101_Restore/blob/95df6b804bee0e01538eb2ddad0413609938d063/System/Library/Frameworks/Photos.framework/PHAssetCreationRequest.m#L7985) reconstructs the adjustment and sets its timestamp from the internal asset capture date. The same file applies `customAssetProperties` later in the creation path. A separate [iOS 18.2 decompilation](https://github.com/EthanArbuckle/iPhone17-1_18.2_22C152_Restore/blob/e26ed4563f78871c59d2d96856756a65d62517e5/System/Library/Frameworks/Photos.framework/PHAssetCreationRequest.m#L7238) shows similar date reconstruction. These observations fit our symptom but do not prove the exact 17.7.2 implementation.

The pinned [17.6.1 PLManagedAsset implementation](https://github.com/SuperChaoM/iPhone15-3_17.6.1_21G101_Restore/blob/95df6b804bee0e01538eb2ddad0413609938d063/System/Library/PrivateFrameworks/PhotoLibraryServices.framework/PLManagedAsset.m#L14774) handles custom properties using key paths. Its [PLUnmanagedAdjustment implementation](https://github.com/SuperChaoM/iPhone15-3_17.6.1_21G101_Restore/blob/95df6b804bee0e01538eb2ddad0413609938d063/System/Library/PrivateFrameworks/PhotoLibraryServices.framework/PLUnmanagedAdjustment.m) propagates a changed adjustment timestamp during `willSave`. This motivates testing exactly `additionalAttributes.unmanagedAdjustment.adjustmentTimestamp` on a new creation request, using the typed original plist date. See the [0.2.7 bounded experiment](TIMESTAMP-EXPERIMENTS-0.2.7.md).

These sources are third-party decompilations, not official Apple documentation/source and not the user's exact OS binary; they can be incomplete or inaccurate. The related resource-service timestamp snippet belongs to a cloud-recovery path and is not evidence about ordinary PhotoKit export. Runtime selector availability, authorization, actual plist persistence and native editor behavior remain to be tested. No normal restore path uses this new property, and no supported solution or device success is claimed.

## 0.2.7 device failure and more precise write-path analysis

One `customAdjustmentDate` trial subsequently completed on the same 50% source. The fixed creation property and its getter accepted the original date, but actual plist export still has capture time instead of the original edit time. An independent copy inspection confirms exactly the same full bytes/date, and inspections of both sources confirm they remain unchanged. DNG, render, full compressed/inflated recipe and fractional capture date match. The actual plist changes only its timestamp; strict restoration remains failed. See [0.2.7 validation](VALIDATION-0.2.7.md).

The [17.6.1 PLManagedAsset adjustment path](https://github.com/SuperChaoM/iPhone15-3_17.6.1_21G101_Restore/blob/95df6b804bee0e01538eb2ddad0413609938d063/System/Library/PrivateFrameworks/PhotoLibraryServices.framework/PLManagedAsset.m#L8875) populates a separate adjustment dictionary and writes it with `_writeOutAdjustmentsToFile:` during ingestion. By contrast, [persistMetadataToFileURL:](https://github.com/SuperChaoM/iPhone15-3_17.6.1_21G101_Restore/blob/95df6b804bee0e01538eb2ddad0413609938d063/System/Library/PrivateFrameworks/PhotoLibraryServices.framework/PLManagedAsset.m#L16359) creates a general filesystem-persistence batch record. Its later invocation after custom properties does not establish a rewrite of the adjustment plist. `PLUnmanagedAdjustment.willSave` propagates a date to the asset, not directly to that file. This is a plausible explanation for the failed approach; the exact 17.7.2 database state and file-write sequence are not directly observed.

Additional pinned third-party sources checked:

- [PHAdjustmentData](https://github.com/SuperChaoM/iPhone15-3_17.6.1_21G101_Restore/blob/95df6b804bee0e01538eb2ddad0413609938d063/System/Library/Frameworks/Photos.framework/PHAdjustmentData.m): no original adjustment-date field found in this sampled implementation.
- [PHContentEditingOutput.assetAdjustmentsWithEditorBundleID:](https://github.com/SuperChaoM/iPhone15-3_17.6.1_21G101_Restore/blob/95df6b804bee0e01538eb2ddad0413609938d063/System/Library/Frameworks/Photos.framework/PHContentEditingOutput.m#L594): constructs a new internal adjustment object from identifier, version, data and base version; no original date is forwarded here.
- [PHAssetChangeRequest](https://github.com/SuperChaoM/iPhone15-3_17.6.1_21G101_Restore/blob/95df6b804bee0e01538eb2ddad0413609938d063/System/Library/Frameworks/Photos.framework/PHAssetChangeRequest.m#L1533): uses that reconstructed object for content-editing submission. Its modification-date setter is a separate operation, already shown insufficient by earlier trials.
- [creationRequestForAssetFromAssetBundle:](https://github.com/SuperChaoM/iPhone15-3_17.6.1_21G101_Restore/blob/95df6b804bee0e01538eb2ddad0413609938d063/System/Library/Frameworks/Photos.framework/PHAssetCreationRequest.m#L10353): wraps the same `addResource` path and capture-date setter; no evidence it bypasses date reconstruction.

These observations narrow the next investigation to the actual adjustment-file ingestion/write path. They do not justify changing backup data, relabeling database time as the original plist time, claiming a private API fixes it, or submitting more identical imports. No additional device copy was created during this read-only research.

## User-suggested icloud-photo-time-fix, 2026-10-20

Reviewed [VenenoSix24/icloud-photo-time-fix at commit 755b24d](https://github.com/VenenoSix24/icloud-photo-time-fix/tree/755b24d3c48b44c5246ee3e6aa84014d6f8994fd), including the record loader, CSV merge, time parser and ExifTool writer. This is a source inspection, not a successful run against the user's photos.

- [app.py](https://github.com/VenenoSix24/icloud-photo-time-fix/blob/755b24d3c48b44c5246ee3e6aa84014d6f8994fd/icloud_ptf/app.py#L17) reads `originalCreationDate` from `Photo Details.csv`, keyed by image filename. It copies input files into a separate output directory before writing.
- [exiftool.py](https://github.com/VenenoSix24/icloud-photo-time-fix/blob/755b24d3c48b44c5246ee3e6aa84014d6f8994fd/icloud_ptf/exiftool.py#L67) writes that same converted capture date into `DateTimeOriginal`, `CreateDate`, `ModifyDate`, `FileModifyDate`, and, on Windows/macOS, `FileCreateDate`. `ModifyDate` here is not a recovered original editing date.
- The accepted CSV fields are `imgName`, `fileChecksum`, `favorite`, `hidden`, `deleted`, `originalCreationDate`, `viewCount`, and `importDate`. The code does not recover an adjustment date from them and has no AAE/`adjustmentTimestamp` or PhotoKit import handling.

This can help with missing capture-time metadata in iCloud downloads. It does not supply the missing step in our restore: the complete source adjustment plist already contains 06:39:47 Beijing, but the restored copy exports 06:28:05, matching capture time. Rewriting the DNG's file or EXIF dates does not establish that Photos preserves the original adjustment timestamp. No user photo, backup, receiver state, or normal restore implementation was changed for this inspection.

## Native macOS experiment with the unchanged photokit helper

The user has Windows and an iPhone, without a Mac. A bounded cloud experiment therefore ran on the existing private repository's GitHub-hosted macOS runner. It used generated XML plists and synthetic payload bytes only. It never accessed a photo library, imported media, or uploaded any user photo or backup. This tests AAE-to-object conversion, not macOS Photos import or iOS restore.

Implementation: [probe_photokit_aae.py](../tools/research/probe_photokit_aae.py), invoked manually by [probe_photo_references.yml](../.github/workflows/probe_photo_references.yml). The upstream helper was fetched unchanged at `62116c2658081e5cf38ced01aabb67f57cb0f6e7` and verified against SHA256 `d7a0d27f0ecf262263ff8509a17a741945806429b8a660dd618572bafdf6787e`. Native Foundation/Photos objects and `NSKeyedArchiver` were used, without mocks.

The first run, [39430741986](https://github.com/LOVEfffFFF/ios_photo_backup_openai/actions/runs/39430741986), failed our initial assertion that date-only input changes would produce identical archives. Inspection showed an important environment difference: macOS 26.6.2's `PHAdjustmentData` has an `adjustmentTimestamp` getter/setter and defaults that field to the current time when constructed. The two archives differed by that runtime-generated date, rather than carrying either original fixture date. The probe was corrected to record the native getter, compare it with the parser-call time window, and compare the archives with only that identified date value normalized. The failed run is not counted as a passing experiment.

The corrected [run 39431830587](https://github.com/LOVEfffFFF/ios_photo_backup_openai/actions/runs/39431830587) completed successfully at repository commit `614cf76949b335b17303370c9a0f019516f2e4e5`, with macOS 26.6.2 arm64, Python 3.12.10 and PyObjC core/Cocoa/Photos 12.2.2. Artifact SHA256: `4b5007706a5870419e7e815c81e8c800b1a0f679da185f9e037123a4495751e5`.

Observed results:

- Two fixtures differing only in their 2020 original adjustment dates produced equal identifier/version/payload/render/base properties. Both native timestamps instead matched the 2026 parser-call window, and native archive dates agreed with those getters. Neither source date survived the helper.
- The archives were structurally identical after normalizing only the identified runtime adjustment date. They were not byte-identical. A changed-payload positive control changed both native payload and archive contents.
- All fixtures had `com.apple.photo` replaced by `com.rhettbull.photokit.apple.photo`, matching upstream's documented behavior. The helper's own warning about losing Apple-editor recognition therefore remains relevant; no editor UI behavior was tested here.
- A separate synthetic in-memory control explicitly set the native macOS timestamp to the source date. Getter/secure-archive round trip retained that value. This establishes an object-level capability on this macOS version only. It does not establish a public/documented setter, availability on iOS 17.7.2, or preservation after Photos ingestion.

The sampled third-party iOS 17.6.1 `PHAdjustmentData` implementation differs from this newer Mac runtime: no timestamp getter/setter or timestamp coding field was found in that sample. It is not the exact user's 17.7.2 runtime. No supported timestamp-preserving import has been established, and these findings do not justify an OS upgrade recommendation or another speculative IPA. The existing 0.2.7 package and normal restore path remain unchanged.
