#!/usr/bin/env python3
"""Publish two notarized betas to PAL feeds; keep Classic's raw IPA separate."""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import re
import sys
import tempfile
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit

import update_source as classic

UPSTREAM = 'https://cdn.altstore.io/file/altstore/marketplace.json'
PREFIX = 'io.github.famsyk.acbs-beta-track-repo'
LIMIT = 128 * 1024 * 1024
HOSTS = {'altstore.io', 'cdn.altstore.io', 'f000.backblazeb2.com'}


@dataclass(frozen=True)
class App:
    listing: str
    actual: str
    item: str
    directory: str
    name: str


APPS = (
    App('io.altstore.AltStore.Beta', 'io.altstore.AltStore', '6478868316',
        'altstore', 'AltStore PAL Beta'),
    App('com.rileytestut.AltStore.Beta', 'com.rileytestut.AltStore.Beta', '6773950481',
        'altstore-classic', 'AltStore Classic Beta'),
)
OUTPUTS = ('source.json', 'pal-source.json', 'classic-source.json')


def public_url(url: str) -> str:
    p = urlsplit(url)
    if (p.scheme != 'https' or p.hostname not in HOSTS or p.username or p.password
            or p.port not in (None, 443) or p.query or p.fragment
            or any(part in p.path for part in ('..', '%', '\\'))):
        raise ValueError('Not a supported public official URL: ' + url)
    return url


class Redirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        public_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def download(url: str, limit: int = 8 * 1024 * 1024) -> bytes:
    public_url(url)
    request = urllib.request.Request(url, headers={
        'User-Agent': 'acbs-catalog/2.0', 'Cache-Control': 'no-cache'
    })
    # No cookie jar or user credentials. An unavailable release stops publication.
    with urllib.request.build_opener(Redirects()).open(request, timeout=60) as response:
        public_url(response.geturl())
        if response.status != 200:
            raise ValueError(f'HTTP {response.status}')
        payload = response.read(limit + 1)
    if len(payload) > limit:
        raise ValueError('Download exceeds safety limit')
    print(f'HTTP 200: {url} ({len(payload)} bytes)', flush=True)
    return payload


def base_url(url: str, app: App) -> str:
    public_url(url)
    base = url.removesuffix('/manifest.json').rstrip('/')
    if not re.fullmatch(r'https://altstore\.io/adps/' + re.escape(app.directory)
                        + r'/[A-Za-z0-9_-]+', base):
        raise ValueError('PAL entry must point to its official ADP, not a raw IPA')
    return base


def select(feed: dict, spec: App) -> tuple[dict, dict, str]:
    found = [a for a in feed['apps'] if a.get('bundleIdentifier') == spec.listing]
    if len(found) != 1 or found[0].get('marketplaceID') != spec.item:
        raise ValueError('Missing, duplicate or incorrect listing: ' + spec.listing)
    app = found[0]
    version = app['versions'][0]  # Order comes from the official source, not string sorting.
    for field in ('version', 'buildVersion', 'date'):
        if not isinstance(version.get(field), str) or not version[field]:
            raise ValueError('Missing release field: ' + field)
    classic.release_date(version['date'])
    if type(version.get('size')) is not int or version['size'] <= 0:
        raise ValueError('Invalid download size')
    return app, version, base_url(version['downloadURL'], spec)


def verify_manifest(manifest: dict, version: dict, spec: App) -> None:
    expected = {'appleItemId': spec.item, 'bundleId': spec.actual,
                'shortVersionString': version['version'], 'bundleVersion': version['buildVersion']}
    for key, value in expected.items():
        if str(manifest.get(key)) != value:
            raise ValueError(f'{spec.name}: {key} expected {value}, got {manifest.get(key)}')
    if manifest.get('isLaunchProhibited') is not False:
        raise ValueError('ADP does not permit launch')
    if 'marketplace' not in manifest.get('appInstallDeterminants', []):
        raise ValueError('Not a marketplace ADP')
    if not isinstance(manifest.get('variants'), list) or not manifest['variants']:
        raise ValueError('ADP has no variants')


def variant_path(variant: dict) -> str:
    path = variant.get('assetPath')
    if not isinstance(path, str) or not re.fullmatch(r'variant/[0-9a-fA-F-]{36}\.ipa', path):
        raise ValueError('Unsafe variant path')
    return path


def choose_variant(manifest: dict) -> dict:
    candidates = []
    for variant in manifest['variants']:
        targets = [t for t in variant.get('installTargets', []) if t.get('device', '').startswith('iPhone')]
        if targets:
            score = max(classic.os_tuple(t['os']) for t in targets)
            candidates.append((score, variant))
    if not candidates:
        raise ValueError('ADP has no iPhone variant')
    result = max(candidates, key=lambda entry: entry[0])[1]
    variant_path(result)
    return result


def verify_variant(payload: bytes, variant: dict) -> str:
    details = variant['variantDetails']
    if type(details['compressedSize']) is not int or len(payload) != details['compressedSize']:
        raise ValueError('Variant size mismatch')
    for descriptor in details.get('hashes', []):
        if descriptor.get('algorithm') != 'sha256':
            continue
        chunk = descriptor.get('chunkSize')
        if type(chunk) is not int or not 0 < chunk <= LIMIT:
            raise ValueError('Invalid chunk size')
        actual = [hashlib.sha256(payload[i:i+chunk]).hexdigest() for i in range(0, len(payload), chunk)]
        if actual and (actual == descriptor.get('encryptedChunkDigests') or actual == descriptor.get('unencryptedChunkDigests')):
            return hashlib.sha256(payload).hexdigest()
    raise ValueError('Variant SHA-256 mismatch')


def old_app(source: dict, spec: App) -> dict | None:
    # A legacy raw-IPA listing is not a comparable PAL version during migration.
    return next((a for a in source.get('apps', []) if a.get('bundleIdentifier') == spec.listing
                 and a.get('marketplaceID') == spec.item), None)


def prevent_rollback(previous: dict | None, version: dict) -> None:
    if not previous:
        return
    old = previous['versions'][0]
    if (classic.release_date(version['date']) < classic.release_date(old['date'])
            or (str(old.get('buildVersion', '')).isdigit() and version['buildVersion'].isdigit()
                and int(version['buildVersion']) < int(old['buildVersion']))):
        raise ValueError('Refusing ADP rollback')


def listing(app: dict, version: dict, spec: App, ipa_version: str) -> dict:
    keep = ('bundleIdentifier', 'marketplaceID', 'developerName', 'iconURL', 'tintColor',
            'category', 'appPermissions', '_regions')
    result = {key: copy.deepcopy(app[key]) for key in keep if key in app}
    display = version.get('marketingVersion', version['version'])
    note = '公式の公開ADPを参照します。アプリ本体や署名は改変しません。実機でのインストールは未検証です。'
    if spec == APPS[1]:
        note += f' PALで導入する版は{display}です。IPA版の{ipa_version}とは配布物が異なります。'
    result.update(name=spec.name, subtitle=f'PALから導入・{display}',
                  localizedDescription=note, versions=[copy.deepcopy(version)])
    # A plain source listing is not a Patreon membership or entitlement grant.
    return result


def catalog(apps: list[dict], checks: dict, ipa_version: str, identifier: str) -> dict:
    return {
        'name': 'ACBS PAL + Classic Beta', 'identifier': identifier,
        'subtitle': 'PAL用：PAL本体とClassicのベータ',
        'description': 'PALから導入する2種類のベータ。通常のIPAを混在させず、公式ADPのID・版・配布ファイルを検証して毎時追従します。実機の導入成功は未検証です。',
        'apps': apps, 'news': [],
        'userInfo': {'catalogVersion': '2', 'classicIPALatest': ipa_version,
                     'deviceInstallation': 'not-tested', 'appleSignatureTrust': 'not-validated-by-this-script',
                     'checks': json.dumps(checks, sort_keys=True, ensure_ascii=False)}
    }


def validate_pal(source: dict) -> None:
    apps = source.get('apps', [])
    if len(apps) != len(APPS) or {a.get('bundleIdentifier') for a in apps} != {s.listing for s in APPS}:
        raise ValueError('Both PAL-compatible beta listings are required, without duplicates')
    for spec in APPS:
        app, version, _ = select(source, spec)
        for field in ('name', 'developerName', 'iconURL', 'localizedDescription'):
            if not isinstance(app.get(field), str) or not app[field]:
                raise ValueError('Missing app field: ' + field)
        # Covers usage descriptions and both supported official permissions formats.
        classic.normalize_permissions(app.get('appPermissions'))
        for field in ('minOSVersion', 'maxOSVersion'):
            if version.get(field):
                classic.os_tuple(version[field])


def load(path: Path) -> dict:
    return json.loads(path.read_text()) if path.exists() else {}


def refresh(root: Path, force: bool = False) -> None:
    prior = load(root / 'source.json')
    # Generate every output in memory/temp storage; never publish a partial failed check.
    with tempfile.TemporaryDirectory(prefix='acbs-catalog-') as tmp:
        ipa_path = Path(tmp) / 'classic.json'
        seed = load(root / 'classic-source.json')
        if not seed and len(prior.get('apps', [])) == 1 and not prior['apps'][0].get('marketplaceID'):
            seed = prior
        if seed:
            ipa_path.write_text(json.dumps(seed))
        classic.sync(json.loads(download(classic.UPSTREAM)), ipa_path,
                     classic.DEFAULT_REPOSITORY, verify_ipa=force)
        ipa_source = load(ipa_path)
    ipa_source.update(name='ACBS Classic IPA Beta (PAL非対応)', identifier=PREFIX + '.classic-ipa')
    ipa_version = ipa_source['apps'][0]['versions'][0]['version']
    feed = json.loads(download(UPSTREAM))
    checks, apps = {}, []
    prior_checks = json.loads(prior.get('userInfo', {}).get('checks', '{}'))
    for spec in APPS:
        app, version, base = select(feed, spec)
        prevent_rollback(old_app(prior, spec), version)
        manifest_data = download(base + '/manifest.json')
        manifest = json.loads(manifest_data)
        verify_manifest(manifest, version, spec)
        signature = download(base + '/signature', 256 * 1024)
        if not signature or signature.lstrip().lower().startswith((b'<html', b'<!doctype')):
            raise ValueError('Signature missing or replaced by HTML')
        variant = choose_variant(manifest)
        path = variant_path(variant)
        current = {'manifestSHA256': hashlib.sha256(manifest_data).hexdigest(),
                   'signatureSHA256': hashlib.sha256(signature).hexdigest(), 'sampleAsset': path}
        previous = prior_checks.get(spec.listing, {})
        reusable = (not force and all(previous.get(k) == v for k, v in current.items())
                    and re.fullmatch(r'[0-9a-f]{64}', previous.get('sampleSHA256', '')))
        if reusable:
            digest = previous['sampleSHA256']
        else:
            length = variant['variantDetails']['compressedSize']
            if type(length) is not int or not 0 < length <= LIMIT:
                raise ValueError('Invalid variant length')
            digest = verify_variant(download(base + '/' + path, length), variant)
        current['sampleSHA256'] = digest
        checks[spec.listing] = current
        apps.append(listing(app, version, spec, ipa_version))
        print(f'ADP_VERIFIED: {spec.name} {version.get("marketingVersion", version["version"])} {digest}', flush=True)
    primary = catalog(apps, checks, ipa_version, PREFIX)
    alias = catalog(copy.deepcopy(apps), checks, ipa_version, PREFIX + '.pal')
    validate_pal(primary)
    validate_pal(alias)
    outputs = dict(zip(OUTPUTS, (primary, alias, ipa_source)))
    encoded = {name: json.dumps(value, ensure_ascii=False, indent=2) + '\n' for name, value in outputs.items()}
    for name, text in encoded.items():
        dest = root / name
        if not dest.exists() or dest.read_text() != text:
            temp = dest.with_suffix('.json.tmp')
            temp.write_text(text, encoding='utf-8')
            os.replace(temp, dest)
    print('CATALOG_OK: source.json and pal-source.json contain only notarized PAL-compatible betas')
    if os.getenv('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
            summary.write('## Published beta catalogs\n\n')
            for app in apps:
                v = app['versions'][0]
                summary.write(f'- {app["name"]}: {v.get("marketingVersion", v["version"])} (PAL ADP)\n')
            summary.write(f'- Classic IPA: {ipa_version} (classic-source.json only)\n\n')
            summary.write('Both ADPs: identifiers, versions and one iPhone asset hash checked. Device installation and Apple signature trust chain are not tested.\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--force', action='store_true')
    args = parser.parse_args()
    try:
        refresh(Path.cwd(), args.force)
    except Exception as exc:
        print(f'CATALOG_FAILED: {type(exc).__name__}: {exc}', file=sys.stderr)
        raise SystemExit(1)
