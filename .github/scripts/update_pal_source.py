#!/usr/bin/env python3
"""Track publicly retrievable, unmodified official AltStore PAL beta ADPs.

This verifies public metadata and one iPhone variant, not iOS installation or
Apple's signature trust chain. It does not request or forge Patreon credentials.
"""
from __future__ import annotations

import copy
import hashlib
import json
import os
import re
import sys
import urllib.request
from datetime import datetime
from pathlib import Path
from urllib.parse import urlsplit

UPSTREAM = 'https://cdn.altstore.io/file/altstore/marketplace.json'
BETA_ID = 'io.altstore.AltStore.Beta'
ACTUAL_ID = 'io.altstore.AltStore'
MARKETPLACE_ID = '6478868316'
HOSTS = {'altstore.io', 'cdn.altstore.io', 'f000.backblazeb2.com'}
OUTPUT = Path('pal-source.json')
MAX_ASSET = 128 * 1024 * 1024


def require_url(url: str) -> str:
    parts = urlsplit(url)
    if parts.scheme != 'https' or parts.hostname not in HOSTS or parts.username or parts.password or parts.query or parts.fragment or parts.port not in (None, 443):
        raise ValueError('URL is outside the public official distribution policy')
    return url


class OfficialRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        require_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def download(url: str, limit: int = 4 * 1024 * 1024) -> bytes:
    require_url(url)
    request = urllib.request.Request(url, headers={
        'User-Agent': 'acbs-pal-beta-track/1.0', 'Cache-Control': 'no-cache'
    })
    # Deliberately no cookie jar, Authorization, Patreon session or Apple account.
    opener = urllib.request.build_opener(OfficialRedirects())
    with opener.open(request, timeout=60) as response:
        if response.status != 200:
            raise ValueError(f'Unexpected HTTP status: {response.status}')
        data = response.read(limit + 1)
        if len(data) > limit:
            raise ValueError('Response exceeds maximum size')
    print(f'HTTP 200: {url} ({len(data)} bytes)', flush=True)
    return data


def select_beta(upstream: dict) -> tuple[dict, dict, str]:
    apps = [a for a in upstream['apps'] if a.get('bundleIdentifier') == BETA_ID]
    if len(apps) != 1 or str(apps[0].get('marketplaceID')) != MARKETPLACE_ID:
        raise ValueError('Missing, ambiguous or unexpected PAL beta listing')
    app = apps[0]
    version = app['versions'][0]
    base = require_url(version['downloadURL']).rstrip('/')
    if base.endswith('/manifest.json'):
        base = base[:-len('/manifest.json')]
    if not base.startswith('https://altstore.io/adps/altstore/'):
        raise ValueError('Latest beta no longer has a supported public official ADP')
    for key in ('version', 'buildVersion', 'date'):
        if not isinstance(version.get(key), str) or not version[key]:
            raise ValueError('Invalid version field: ' + key)
    datetime.fromisoformat(version['date'].replace('Z', '+00:00'))
    return app, version, base


def verify_manifest(manifest: dict, version: dict) -> None:
    for key, expected in (
        ('appleItemId', MARKETPLACE_ID), ('bundleId', ACTUAL_ID),
        ('shortVersionString', version['version']), ('bundleVersion', version['buildVersion'])
    ):
        if str(manifest.get(key)) != str(expected):
            raise ValueError('Manifest mismatch: ' + key)
    if manifest.get('isLaunchProhibited') is not False:
        raise ValueError('Manifest does not permit launch')
    if 'marketplace' not in manifest.get('appInstallDeterminants', []):
        raise ValueError('Not a marketplace distribution package')
    if not isinstance(manifest.get('variants'), list) or not manifest['variants']:
        raise ValueError('Manifest has no variants')


def asset_path(variant: dict) -> str:
    path = variant['assetPath']
    if not isinstance(path, str) or not re.fullmatch(r'variant/[0-9a-fA-F-]{36}\.ipa', path):
        raise ValueError('Unexpected or unsafe variant path')
    return path


def select_iphone_variant(manifest: dict) -> dict:
    variants = [v for v in manifest['variants'] if any(
        t.get('device', '').startswith('iPhone') for t in v.get('installTargets', [])
    )]
    if not variants:
        raise ValueError('No iPhone variant')
    def latest_os(variant):
        return max(tuple(int(x) for x in t['os'].split('.')) for t in variant['installTargets'] if t.get('device', '').startswith('iPhone'))
    variant = max(variants, key=latest_os)
    asset_path(variant)
    return variant


def verify_variant(data: bytes, variant: dict) -> str:
    details = variant['variantDetails']
    if len(data) != details['compressedSize']:
        raise ValueError('Downloaded variant size mismatch')
    hashes = [h for h in details['hashes'] if h.get('algorithm') == 'sha256']
    for descriptor in hashes:
        size = descriptor.get('chunkSize')
        if not isinstance(size, int) or not 0 < size <= MAX_ASSET:
            raise ValueError('Invalid SHA-256 chunk size')
        got = [hashlib.sha256(data[i:i+size]).hexdigest() for i in range(0, len(data), size)]
        # Compare a complete list; never mix encrypted and unencrypted chunks.
        if got == descriptor.get('encryptedChunkDigests') or got == descriptor.get('unencryptedChunkDigests'):
            return hashlib.sha256(data).hexdigest()
    raise ValueError('Variant does not match any manifest SHA-256 digest set')


def prevent_rollback(old: dict, version: dict) -> None:
    if not old:
        return
    old_version = old['apps'][0]['versions'][0]
    old_date = datetime.fromisoformat(old_version['date'].replace('Z', '+00:00'))
    new_date = datetime.fromisoformat(version['date'].replace('Z', '+00:00'))
    if new_date < old_date:
        raise ValueError('Refusing upstream rollback')


def make_source(app: dict, version: dict, checks: dict[str, str]) -> dict:
    result = {key: copy.deepcopy(app[key]) for key in (
        'bundleIdentifier', 'marketplaceID', 'developerName', 'iconURL',
        'tintColor', 'category', 'appPermissions', '_regions'
    ) if key in app}
    result.update({
        'name': 'AltStore PAL Beta',
        'subtitle': 'PAL本体のベータ・非公式参照ソース',
        'localizedDescription': 'AltStore PAL本体用。認証なしに取得できた公式ADPを参照する非公式ソースです。アプリ本体・署名は改変しません。iPhoneでの更新成功は未確認です。Patreon特典の利用権を付与するものではありません。',
        'versions': [copy.deepcopy(version)]
    })
    return {
        'name': 'ACBS PAL Beta Track',
        'identifier': 'io.github.famsyk.acbs-beta-track-repo.pal',
        'subtitle': 'AltStore PAL本体向け・非公式ベータ追従',
        'description': '公式PALソースを毎時確認します。公開ADPの情報を照合し、変更時にはiPhone用配布ファイル1件をハッシュ検証して掲載します。実機での導入は未検証です。',
        'website': 'https://github.com/famsyk/acbs-beta-track-repo',
        'apps': [result], 'news': [], 'userInfo': checks
    }


def main() -> None:
    upstream = json.loads(download(UPSTREAM))
    app, version, base = select_beta(upstream)
    old = json.loads(OUTPUT.read_text()) if OUTPUT.exists() else {}
    prevent_rollback(old, version)
    manifest_bytes = download(base + '/manifest.json')
    manifest = json.loads(manifest_bytes)
    verify_manifest(manifest, version)
    signature = download(base + '/signature', 256 * 1024)
    if not signature or signature.lstrip().lower().startswith((b'<html', b'<!doctype')):
        raise ValueError('Signature is missing or is an HTML page')
    # The signature is fetched and fingerprinted, not verified against Apple's trust chain.
    checks = {
        'validationVersion': '1',
        'manifestSHA256': hashlib.sha256(manifest_bytes).hexdigest(),
        'signatureSHA256': hashlib.sha256(signature).hexdigest(),
        'deviceInstallation': 'not-tested',
        'appleSignatureTrust': 'not-validated-by-this-script'
    }
    variant = select_iphone_variant(manifest)
    path = asset_path(variant)
    old_checks = old.get('userInfo', {})
    reusable = all(old_checks.get(k) == v for k, v in checks.items()) and old_checks.get('sampleAsset') == path and re.fullmatch(r'[0-9a-f]{64}', old_checks.get('sampleSHA256', ''))
    if reusable:
        digest = old_checks['sampleSHA256']
        print('Unchanged manifest/signature: reusing previous iPhone sample verification')
    else:
        length = variant['variantDetails']['compressedSize']
        if not isinstance(length, int) or not 0 < length <= MAX_ASSET:
            raise ValueError('iPhone variant is too large')
        data = download(base + '/' + path, length)
        digest = verify_variant(data, variant)
        print(f'IPHONE_VARIANT_VERIFIED: {path} size={len(data)} sha256={digest}')
    checks.update({'sampleAsset': path, 'sampleSHA256': digest})
    result = make_source(app, version, checks)
    text = json.dumps(result, ensure_ascii=False, indent=2) + '\n'
    if not OUTPUT.exists() or OUTPUT.read_text() != text:
        temporary = OUTPUT.with_suffix('.json.tmp')
        temporary.write_text(text, encoding='utf-8')
        os.replace(temporary, OUTPUT)
        print('PAL_SOURCE_UPDATED: ' + version.get('marketingVersion', version['version']))
    else:
        print('PAL_SOURCE_UNCHANGED')
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
            summary.write('## PAL beta source\n\n')
            summary.write('Official release: ' + version.get('marketingVersion', version['version']) + '\n\n')
            summary.write('Manifest and signature fetched without authentication; source fields match manifest. One iPhone variant SHA-256 verified (or reused for identical metadata).\n\n')
            summary.write('No IPA is rehosted. Actual iOS installation and Apple signature trust-chain validation are NOT performed by this workflow.\n')


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print(f'PAL_TRACKER_FAILED: {type(exc).__name__}: {exc}', file=sys.stderr)
        print('Previously published PAL source was not overwritten.', file=sys.stderr)
        sys.exit(1)
