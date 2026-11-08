"""Probe pinned upstream AAE handling with native macOS objects, without a library.

All fixtures are generated here. No image, photo library, or user backup is read.
This is an object-conversion experiment, not a Photos import or iOS restore test.
"""

import argparse
import base64
import copy
import datetime
import hashlib
import importlib.metadata
import importlib.util
import json
import os
import pathlib
import platform
import plistlib
import sys
import time
import urllib.request


UPSTREAM_COMMIT = "62116c2658081e5cf38ced01aabb67f57cb0f6e7"
UPSTREAM_URL = (
    "https://raw.githubusercontent.com/RhetTbull/photokit/"
    f"{UPSTREAM_COMMIT}/photokit/aae.py"
)
UPSTREAM_SHA256 = "d7a0d27f0ecf262263ff8509a17a741945806429b8a660dd618572bafdf6787e"


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def json_value(value):
    if isinstance(value, bytes):
        return {"base64": base64.b64encode(value).decode("ascii")}
    if isinstance(value, plistlib.UID):
        return {"uid": value.data}
    if isinstance(value, datetime.datetime):
        return {"utc_date": value.isoformat() + "Z"}
    if isinstance(value, dict):
        return {key: json_value(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [json_value(item) for item in value]
    return value


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def archive_timestamp_object(archive):
    root = archive["$objects"][archive["$top"]["root"].data]
    reference = root.get("adjustmentTimestamp")
    if reference is None or reference.data == 0:
        return None
    date = archive["$objects"][reference.data]
    require("NS.time" in date, "Unexpected archived timestamp representation")
    return date


def normalize_runtime_timestamp(archive):
    normalized = copy.deepcopy(archive)
    date = archive_timestamp_object(normalized)
    if date is not None:
        date["NS.time"] = "<runtime adjustmentTimestamp>"
    return normalized


def run(output, report):
    require(sys.platform == "darwin", "A real macOS Photos framework is required")
    import Foundation
    import Photos

    report["environment"] = {
        "macos": platform.mac_ver()[0],
        "machine": platform.machine(),
        "python": platform.python_version(),
        "photos_framework": str(Photos.__bundle__.bundlePath()),
        "repository_commit": os.environ.get("GITHUB_SHA"),
        "github_run_id": os.environ.get("GITHUB_RUN_ID"),
        "packages": {
            name: importlib.metadata.version(name)
            for name in ("pyobjc-core", "pyobjc-framework-Cocoa", "pyobjc-framework-Photos")
        },
    }
    with urllib.request.urlopen(UPSTREAM_URL, timeout=40) as response:
        source = response.read()
    require(sha256(source) == UPSTREAM_SHA256, "Pinned upstream source hash mismatch")
    upstream_path = output / "upstream-aae.py"
    upstream_path.write_bytes(source)
    report["upstream"] = {
        "url": UPSTREAM_URL,
        "commit": UPSTREAM_COMMIT,
        "sha256": sha256(source),
        "unchanged": True,
    }
    spec = importlib.util.spec_from_file_location("pinned_upstream_aae", upstream_path)
    upstream = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(upstream)

    fixture = {
        "adjustmentFormatIdentifier": "com.apple.photo",
        "adjustmentFormatVersion": "1.9.1",
        "adjustmentData": b"synthetic-probe-payload-A; not a real Apple edit recipe",
        "adjustmentEditorBundleID": "com.apple.Photos",
        "adjustmentRenderTypes": 3072,
        "adjustmentBaseVersion": 0,
        "adjustmentTimestamp": datetime.datetime(2020, 1, 2, 3, 4, 5),
    }
    fixtures = {
        "date_a": fixture,
        "date_b": {
            **fixture,
            "adjustmentTimestamp": datetime.datetime(2020, 2, 3, 4, 5, 6),
        },
        "payload_control": {
            **fixture,
            "adjustmentData": b"synthetic-probe-payload-B; not a real Apple edit recipe",
        },
    }
    require(
        [key for key in fixture if fixture[key] != fixtures["date_b"][key]]
        == ["adjustmentTimestamp"],
        "Date comparison must have exactly one changed input field",
    )
    native_states = {}
    archives = {}
    archive_bytes = {}
    normalized_archives = {}
    source_date_retained = {}
    default_date_is_now = {}
    report["cases"] = {}
    for name, values in fixtures.items():
        fixture_bytes = plistlib.dumps(values, fmt=plistlib.FMT_XML)
        fixture_path = output / f"{name}.AAE"
        fixture_path.write_bytes(fixture_bytes)
        before = time.time()
        adjustment = upstream.adjustment_data_from_aae(fixture_path)
        after = time.time()
        require(adjustment is not None, f"Upstream parser returned None for {name}")
        require(
            isinstance(adjustment, Photos.PHAdjustmentData),
            "Probe must use the real native PHAdjustmentData class",
        )
        state = {
            "format_identifier": str(adjustment.formatIdentifier()),
            "format_version": str(adjustment.formatVersion()),
            "data": bytes(adjustment.data()),
            "render_types": int(adjustment.adjustmentRenderTypes()),
            "base_version": int(adjustment.baseVersion()),
            "has_adjustment_timestamp_getter": bool(
                adjustment.respondsToSelector_("adjustmentTimestamp")
            ),
            "has_adjustment_timestamp_setter": bool(
                adjustment.respondsToSelector_("setAdjustmentTimestamp:")
            ),
        }
        native_date = (
            adjustment.adjustmentTimestamp()
            if state["has_adjustment_timestamp_getter"]
            else None
        )
        native_unix = (
            float(native_date.timeIntervalSince1970()) if native_date is not None else None
        )
        input_unix = values["adjustmentTimestamp"].replace(
            tzinfo=datetime.timezone.utc
        ).timestamp()
        source_date_retained[name] = native_unix == input_unix
        default_date_is_now[name] = (
            before - 1 <= native_unix <= after + 1 if native_unix is not None else None
        )
        require(state["data"] == values["adjustmentData"], "Payload unexpectedly changed")
        require(state["format_version"] == "1.9.1", "Format version unexpectedly changed")
        require(state["render_types"] == 3072, "Render types unexpectedly changed")
        require(state["base_version"] == 0, "Base version unexpectedly changed")
        require(
            state["format_identifier"] == "com.rhettbull.photokit.apple.photo",
            "Upstream Apple-identifier substitution was not reproduced",
        )
        encoded, error = (
            Foundation.NSKeyedArchiver.archivedDataWithRootObject_requiringSecureCoding_error_(
                adjustment, True, None
            )
        )
        require(encoded is not None and error is None, f"Native archive failed: {error}")
        encoded = bytes(encoded)
        decoded = plistlib.loads(encoded)
        archived_date = archive_timestamp_object(decoded)
        archived_unix = (
            archived_date["NS.time"] + 978307200 if archived_date is not None else None
        )
        if native_unix is not None:
            require(
                archived_unix is not None and abs(archived_unix - native_unix) < 0.00001,
                "Archived timestamp does not match the native getter",
            )
        (output / f"{name}.archive.bplist").write_bytes(encoded)
        native_states[name] = state
        archives[name] = decoded
        archive_bytes[name] = encoded
        normalized_archives[name] = normalize_runtime_timestamp(decoded)
        report["cases"][name] = {
            "input": values,
            "input_sha256": sha256(fixture_bytes),
            "native_state": state,
            "native_timestamp_unix": native_unix,
            "native_timestamp_is_parser_call_time": default_date_is_now[name],
            "source_timestamp_retained": source_date_retained[name],
            "archive_sha256": sha256(encoded),
            "archive_bytes": len(encoded),
            "archive_contents": decoded,
        }

        if name == "date_a" and state["has_adjustment_timestamp_setter"]:
            # Separate control on this synthetic in-memory object; upstream stays unchanged.
            wanted = Foundation.NSDate.dateWithTimeIntervalSince1970_(input_unix)
            adjustment.setAdjustmentTimestamp_(wanted)
            explicit, explicit_error = (
                Foundation.NSKeyedArchiver.archivedDataWithRootObject_requiringSecureCoding_error_(
                    adjustment, True, None
                )
            )
            require(explicit is not None and explicit_error is None, "Setter control archive failed")
            explicit_bytes = bytes(explicit)
            explicit_archive = plistlib.loads(explicit_bytes)
            explicit_date = archive_timestamp_object(explicit_archive)
            require(explicit_date is not None, "Setter control has no archived date")
            explicit_unix = explicit_date["NS.time"] + 978307200
            require(explicit_unix == input_unix, "Native in-memory date setter did not persist to archive")
            (output / "explicit-date-control.archive.bplist").write_bytes(explicit_bytes)
            report["explicit_date_control"] = {
                "scope": "This macOS in-memory object only; no Photos library import",
                "timestamp_unix": explicit_unix,
                "matches_input_date": explicit_unix == input_unix,
                "archive_sha256": sha256(explicit_bytes),
            }

    observations = {
        "different_input_dates_same_native_state": native_states["date_a"]
        == native_states["date_b"],
        "different_input_dates_same_archive_structure": archives["date_a"]
        == archives["date_b"],
        "different_input_dates_same_archive_bytes": archive_bytes["date_a"]
        == archive_bytes["date_b"],
        "same_archive_except_runtime_timestamp": normalized_archives["date_a"]
        == normalized_archives["date_b"],
        "any_source_timestamp_retained": any(source_date_retained.values()),
        "all_native_timestamps_default_to_call_time": all(
            value is True for value in default_date_is_now.values()
        ),
        "changed_payload_changes_native_state": native_states["date_a"]
        != native_states["payload_control"],
        "changed_payload_changes_archive_structure": archives["date_a"]
        != archives["payload_control"],
    }
    report["observations"] = observations
    # These assertions check this pinned helper's observed behavior, not restore success.
    for key in (
        "different_input_dates_same_native_state",
        "same_archive_except_runtime_timestamp",
        "changed_payload_changes_native_state",
        "changed_payload_changes_archive_structure",
    ):
        require(observations[key], f"Unexpected upstream/native behavior: {key}")
    require(not observations["any_source_timestamp_retained"], "Unexpected upstream source date forwarding")
    report["status"] = "completed"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    report = {
        "status": "started",
        "scope": "Synthetic AAE to native PHAdjustmentData conversion and archiving only",
        "photo_library_access": False,
        "real_photos_used": False,
        "ios_device_test": False,
        "photos_import_test": False,
    }
    try:
        run(args.output, report)
    except Exception as error:
        report["status"] = "error"
        report["error"] = f"{type(error).__name__}: {error}"
        raise
    finally:
        encoded = json.dumps(json_value(report), indent=2, sort_keys=True) + "\n"
        (args.output / "report.json").write_text(encoded, encoding="utf-8")
        print(encoded)


if __name__ == "__main__":
    main()
