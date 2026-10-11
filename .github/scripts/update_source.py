#!/usr/bin/env python3
"""Track the official AltStore Classic beta feed; publish only verified public IPAs.

The script never executes, re-signs, or republishes the downloaded application.
Only source.json is written, atomically, after all validation has succeeded.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import struct
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

UPSTREAM = "https://cdn.altstore.io/file/altstore/apps.json"
BUNDLE_ID = "com.rileytestut.AltStore.Beta"
DEFAULT_REPOSITORY = "famsyk/acbs-beta-track-repo"
MAX_IPA = 512 * 1024 * 1024
AUTO_ENTITLEMENTS = {"application-identifier", "com.apple.developer.team-identifier"}


class SyncError(Exception):
    """A failed check. The previously published source must remain unchanged."""


def public_url(url: str) -> str:
    """Permit only the official feed and its public Classic IPA directory."""
    if not isinstance(url, str):
        raise SyncError("Download URL is not a string")
    p = urllib.parse.urlsplit(url)
    try:
        port = p.port
    except ValueError as exc:
        raise SyncError("Invalid URL port") from exc
    is_feed = url == UPSTREAM
    is_ipa = p.path.startswith("/file/altstore/apps/altstore/") and p.path.endswith(".ipa")
    if (p.scheme != "https" or p.hostname != "cdn.altstore.io" or
            port not in (None, 443) or p.username or p.password or p.query or
            p.fragment or not (is_feed or is_ipa) or
            any(s in p.path for s in ("..", "%", "\\"))):
        raise SyncError("Latest release is not a supported public official CDN IPA; keeping the previous version")
    return url


class PublicRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        public_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def fetch_to(url: str, dest: Path, limit: int) -> None:
    public_url(url)
    opener = urllib.request.build_opener(PublicRedirect())
    for attempt in range(3):
        try:
            req = urllib.request.Request(url, headers={
                "User-Agent": "acbs-beta-track-repo/1.0",
                "Cache-Control": "no-cache",
            })
            with opener.open(req, timeout=45) as response, dest.open("wb") as output:
                public_url(response.geturl())
                total = 0
                while chunk := response.read(1024 * 1024):
                    total += len(chunk)
                    if total > limit:
                        raise SyncError("Response exceeds the safety size limit")
                    output.write(chunk)
            return
        except urllib.error.HTTPError as exc:
            if exc.code not in (429, 500, 502, 503, 504) or attempt == 2:
                raise SyncError(f"Official server returned HTTP {exc.code}; source not updated") from exc
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            if attempt == 2:
                raise SyncError(f"Download failed: {exc}") from exc
        time.sleep(2 ** attempt)
    raise SyncError("Download failed")


def release_date(value: Any) -> datetime:
    if not isinstance(value, str):
        raise SyncError("Missing release date")
    try:
        dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise SyncError("Invalid release date") from exc
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def select_latest(feed: dict[str, Any]) -> tuple[dict, dict]:
    apps = feed.get("apps")
    if not isinstance(apps, list):
        raise SyncError("Official feed has no apps array")
    matches = [a for a in apps if isinstance(a, dict) and a.get("bundleIdentifier") == BUNDLE_ID]
    if len(matches) != 1:
        raise SyncError("Expected exactly one official Classic beta entry")
    app = matches[0]
    versions = app.get("versions")
    if not isinstance(versions, list) or not versions or not isinstance(versions[0], dict):
        raise SyncError("Beta entry has no versions")
    # AltStore defines the first entry as latest. Never sort b9/b10 lexicographically.
    version = versions[0]
    if not isinstance(version.get("version"), str) or not version["version"].strip():
        raise SyncError("Invalid version string")
    release_date(version.get("date"))
    if type(version.get("size")) is not int or not 0 < version["size"] <= MAX_IPA:
        raise SyncError("Invalid IPA size")
    if not isinstance(version.get("sha256"), str) or not re.fullmatch(r"[0-9a-fA-F]{64}", version["sha256"]):
        raise SyncError("Official SHA-256 missing or malformed; refusing an unverified update")
    public_url(version.get("downloadURL"))
    if not urllib.parse.urlsplit(version["downloadURL"]).path.endswith(".ipa"):
        raise SyncError("Latest version does not point to an IPA")
    return app, version


def normalize_permissions(value: Any) -> dict:
    if value is None:
        value = {}
    if not isinstance(value, dict):
        raise SyncError("Invalid appPermissions")
    entitlements = value.get("entitlements", [])
    if not isinstance(entitlements, list):
        raise SyncError("Invalid entitlements list")
    names = set()
    for entry in entitlements:
        name = entry.get("name") if isinstance(entry, dict) else entry
        if not isinstance(name, str) or not name:
            raise SyncError("Invalid entitlement name")
        names.add(name)
    privacy = value.get("privacy", {})
    if isinstance(privacy, list):
        converted = {}
        for entry in privacy:
            if not isinstance(entry, dict) or not isinstance(entry.get("name"), str):
                raise SyncError("Invalid privacy entry")
            key = entry["name"]
            if not (key.startswith("NS") and key.endswith("UsageDescription")):
                key = "NS" + key + "UsageDescription"
            converted[key] = entry.get("usageDescription", "")
        privacy = converted
    if not isinstance(privacy, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in privacy.items()):
        raise SyncError("Invalid privacy permissions")
    return {"entitlements": sorted(names - AUTO_ENTITLEMENTS), "privacy": dict(sorted(privacy.items()))}


def unpack(fmt: str, data: bytes, offset: int) -> tuple:
    size = struct.calcsize(fmt)
    if offset < 0 or offset + size > len(data):
        raise SyncError("Truncated Mach-O code signature")
    return struct.unpack_from(fmt, data, offset)


def macho_entitlements(data: bytes) -> set[str]:
    """Read signed XML entitlements using Mach-O offsets, not string searching."""
    magic = data[:4]
    if magic in (b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"):
        endian = ">" if magic[:1] == b"\xca" else "<"
        is64 = magic in (b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca")
        count, = unpack(endian + "I", data, 4)
        if not 0 < count <= 32:
            raise SyncError("Invalid universal Mach-O architecture count")
        result = set()
        for i in range(count):
            values = unpack(endian + ("IIQQII" if is64 else "IIIII"), data, 8 + i * (32 if is64 else 20))
            offset, size = values[2:4]
            if offset + size > len(data):
                raise SyncError("Truncated universal Mach-O")
            result |= macho_entitlements(data[offset:offset + size])
        return result
    layouts = {
        b"\xcf\xfa\xed\xfe": ("<", 32), b"\xce\xfa\xed\xfe": ("<", 28),
        b"\xfe\xed\xfa\xcf": (">", 32), b"\xfe\xed\xfa\xce": (">", 28),
    }
    if magic not in layouts:
        raise SyncError("Unsupported application executable format")
    endian, offset = layouts[magic]
    count, commands_size = unpack(endian + "II", data, 16)
    end = offset + commands_size
    if count > 65536 or end > len(data):
        raise SyncError("Invalid Mach-O load commands")
    result, found_signature = set(), False
    for _ in range(count):
        command, size = unpack(endian + "II", data, offset)
        if size < 8 or offset + size > end:
            raise SyncError("Invalid Mach-O load command size")
        if command == 0x1D:  # LC_CODE_SIGNATURE
            if size < 16:
                raise SyncError("Invalid code signature command")
            start, length = unpack(endian + "II", data, offset + 8)
            if start + length > len(data):
                raise SyncError("Code signature outside executable")
            signature = data[start:start + length]
            blob_magic, blob_len, blob_count = unpack(">III", signature, 0)
            if blob_magic != 0xFADE0CC0 or blob_len > len(signature) or 12 + 8 * blob_count > blob_len:
                raise SyncError("Invalid embedded code signature")
            xml_found, der_found = False, False
            for i in range(blob_count):
                _, loc = unpack(">II", signature, 12 + i * 8)
                bm, bl = unpack(">II", signature, loc)
                if bl < 8 or loc + bl > blob_len:
                    raise SyncError("Invalid code signature sub-blob")
                if bm == 0xFADE7171:
                    entitlements = plistlib.loads(signature[loc + 8:loc + bl])
                    if not isinstance(entitlements, dict):
                        raise SyncError("Entitlements are not a dictionary")
                    result.update(entitlements)
                    xml_found = True
                elif bm == 0xFADE7172:
                    der_found = True
            if der_found and not xml_found:
                raise SyncError("DER-only entitlements are not supported; refusing to omit permissions")
            found_signature = True
        offset += size
    if not found_signature:
        raise SyncError("Expected a signed official executable")
    return result - AUTO_ENTITLEMENTS


def inspect_ipa(path: Path, version: dict) -> tuple[dict, dict]:
    if path.stat().st_size != version["size"]:
        raise SyncError("IPA byte size differs from the official feed")
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    if digest.hexdigest() != version["sha256"].lower():
        raise SyncError("IPA SHA-256 mismatch")
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise SyncError("Duplicate paths in IPA")
        roots = [n for n in names if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n)]
        if len(roots) != 1:
            raise SyncError("IPA must contain one main application")
        if any(i.file_size > MAX_IPA for i in archive.infolist()):
            raise SyncError("IPA contains an oversized member")
        info = plistlib.loads(archive.read(roots[0]))
        if info.get("CFBundleIdentifier") != BUNDLE_ID:
            raise SyncError("IPA bundle identifier does not match Classic beta")
        if info.get("CFBundleShortVersionString") != version["version"]:
            raise SyncError("IPA version does not match the official feed")
        build = info.get("CFBundleVersion")
        if not isinstance(build, str) or not build:
            raise SyncError("IPA build number missing")
        if version.get("buildVersion") is not None and str(version["buildVersion"]) != build:
            raise SyncError("IPA build number differs from the official feed")
        entitlements, privacy = set(), {}
        for name in names:
            if not name.startswith("Payload/") or not re.search(r"\.(?:app|appex)/Info\.plist$", name):
                continue
            bundle = plistlib.loads(archive.read(name))
            executable = bundle.get("CFBundleExecutable")
            if not isinstance(executable, str) or "/" in executable or executable in (".", ".."):
                raise SyncError("Invalid executable name in bundle")
            binary = archive.read(name.rsplit("/", 1)[0] + "/" + executable)
            entitlements |= macho_entitlements(binary)
            for key, value in bundle.items():
                if re.fullmatch(r"NS.*UsageDescription", key):
                    if not isinstance(value, str):
                        raise SyncError("Non-string privacy usage description")
                    privacy[key] = value
        # Main application's descriptions take priority over extension descriptions.
        privacy.update({k: v for k, v in info.items() if re.fullmatch(r"NS.*UsageDescription", k)})
    return info, {"entitlements": sorted(entitlements), "privacy": dict(sorted(privacy.items()))}


def os_tuple(value: str) -> tuple[int, ...]:
    if not isinstance(value, str) or not re.fullmatch(r"\d+(?:\.\d+){0,3}", value):
        raise SyncError("Invalid minimum OS version")
    return tuple(map(int, value.split(".")))


def previous_app(source: dict | None) -> dict | None:
    if source is None:
        return None
    apps = source.get("apps", [])
    if len(apps) != 1 or apps[0].get("bundleIdentifier") != BUNDLE_ID:
        raise SyncError("Existing source is not a single Classic beta source")
    if not apps[0].get("versions"):
        raise SyncError("Existing source has no versions")
    return apps[0]


def sync(feed: dict, output: Path, repository: str, ipa: Path | None = None, *, verify_ipa: bool = False) -> bool:
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise SyncError("Invalid repository name")
    owner, repo = repository.split("/")
    official_app, latest = select_latest(feed)
    previous = json.loads(output.read_text()) if output.exists() else None
    old_app = previous_app(previous)
    old_version = old_app["versions"][0] if old_app else {}
    if old_version and release_date(old_version["date"]) > release_date(latest["date"]):
        raise SyncError("Upstream would roll back the current release; keeping the previous version")
    cache_ok = (not verify_ipa and ipa is None and old_app is not None and
                all(old_version.get(k) == latest.get(k) for k in ("version", "sha256", "size")) and
                bool(old_version.get("buildVersion")) and "appPermissions" in old_app)
    if cache_ok:
        info = {"CFBundleVersion": old_version["buildVersion"],
                "MinimumOSVersion": old_version.get("minOSVersion")}
        actual = normalize_permissions(old_app["appPermissions"])
        if latest.get("buildVersion") is not None and str(latest["buildVersion"]) != info["CFBundleVersion"]:
            raise SyncError("Cached IPA build differs from upstream")
    else:
        with tempfile.TemporaryDirectory(prefix="acbs-ipa-") as directory:
            local = ipa or Path(directory) / "latest.ipa"
            if ipa is None:
                fetch_to(latest["downloadURL"], local, MAX_IPA)
            info, actual = inspect_ipa(local, latest)
    supplied = normalize_permissions(official_app.get("appPermissions"))
    permissions = {
        "entitlements": sorted(set(actual["entitlements"]) | set(supplied["entitlements"])),
        "privacy": dict(sorted({**supplied["privacy"], **actual["privacy"]}.items())),
    }
    fields = ("version", "date", "downloadURL", "size", "maxOSVersion")
    release = {k: latest[k] for k in fields if k in latest}
    release["sha256"] = latest["sha256"].lower()
    release["buildVersion"] = info["CFBundleVersion"]
    release["marketingVersion"] = f'{latest["version"]} ({info["CFBundleVersion"]})'
    release["localizedDescription"] = latest.get("localizedDescription", "公式ソースから取得したベータ版。")
    minimums = [v for v in (latest.get("minOSVersion"), info.get("MinimumOSVersion")) if v]
    if minimums:
        release["minOSVersion"] = max(minimums, key=os_tuple)
    if release.get("maxOSVersion"):
        os_tuple(release["maxOSVersion"])
    icon = official_app.get("iconURL")
    if not isinstance(icon, str) or not icon.startswith("https://"):
        raise SyncError("Official app icon URL missing")
    source = {
        "name": "ACBS Beta Track",
        "identifier": f"io.github.{owner}.{repo}",
        "subtitle": "AltStore Classic Beta・非公式追従ソース",
        "description": "公式ソースを毎時確認する非公式ソース。検証できた最新の公開CDN版IPAを参照します。AltStore PAL非対応。",
        "website": f"https://github.com/{repository}",
        "apps": [{
            "name": "AltStore Classic Beta",
            "bundleIdentifier": BUNDLE_ID,
            "developerName": official_app.get("developerName", "Riley Testut"),
            "subtitle": "公式CDNのベータ版を追従",
            "localizedDescription": "AltStore Classic専用の非公式ソース。IPAは公式CDNから直接取得し、本体の改変・再配布は行いません。公開URLで取得・検証できる版のみ掲載します。インストールと署名更新はAltStore側で行ってください。",
            "iconURL": icon,
            "tintColor": official_app.get("tintColor", "018084"),
            "category": "utilities",
            "versions": [release],
            "appPermissions": permissions,
        }],
        "news": [],
    }
    text = json.dumps(source, ensure_ascii=False, indent=2) + "\n"
    if output.exists() and output.read_text() == text:
        print(f"Already current: {release['marketingVersion']!r}; " + ("reusing verified metadata" if cache_ok else "IPA verified"))
        return False
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=output.parent, delete=False) as file:
            temporary = Path(file.name)
            file.write(text)
        os.replace(temporary, output)
    finally:
        if temporary and temporary.exists():
            temporary.unlink()
    print(f"Verified source updated: {release['marketingVersion']!r}")
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("source.json"))
    parser.add_argument("--repository", default=os.getenv("GITHUB_REPOSITORY", DEFAULT_REPOSITORY))
    parser.add_argument("--feed", type=Path, help="Local feed fixture, for offline testing")
    parser.add_argument("--ipa", type=Path, help="Local official IPA, still hash-checked")
    parser.add_argument("--verify-ipa", action="store_true", help="Re-download and inspect even an unchanged IPA")
    args = parser.parse_args()
    try:
        with tempfile.TemporaryDirectory(prefix="acbs-feed-") as directory:
            feed_path = args.feed or Path(directory) / "apps.json"
            if args.feed is None:
                fetch_to(UPSTREAM, feed_path, 8 * 1024 * 1024)
            feed = json.loads(feed_path.read_text(encoding="utf-8-sig"))
            sync(feed, args.output, args.repository, args.ipa, verify_ipa=args.verify_ipa)
        return 0
    except Exception as exc:
        print(f"ERROR: {exc}\nPrevious source.json has not been replaced.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
