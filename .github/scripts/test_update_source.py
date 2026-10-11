"""Offline regression tests; no network calls or real credentials required."""
from __future__ import annotations
import copy
import hashlib
import json
import plistlib
import struct
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch
import update_source as tracker


def executable(entitlements: dict) -> bytes:
    xml = plistlib.dumps(entitlements)
    blob = struct.pack('>II', 0xFADE7171, len(xml) + 8) + xml
    signature = struct.pack('>III', 0xFADE0CC0, 20 + len(blob), 1) + struct.pack('>II', 5, 20) + blob
    header = struct.pack('<IiiIIIII', 0xFEEDFACF, 0x100000C, 0, 2, 1, 16, 0, 0)
    return header + struct.pack('<IIII', 0x1D, 16, 48, len(signature)) + signature


class TrackerTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.ipa = self.root / 'beta.ipa'
        self.output = self.root / 'source.json'
        self.info = {
            'CFBundleIdentifier': tracker.BUNDLE_ID,
            'CFBundleShortVersionString': '3.0b10',
            'CFBundleVersion': '100',
            'CFBundleExecutable': 'App',
            'MinimumOSVersion': '17.4',
            'NSLocalNetworkUsageDescription': 'Find the server.',
        }
        self.write_ipa()
        self.version = {
            'version': '3.0b10', 'date': '2026-10-11T03:00:00Z',
            'downloadURL': 'https://cdn.altstore.io/file/altstore/apps/altstore/test.ipa',
            'size': self.ipa.stat().st_size,
            'sha256': hashlib.sha256(self.ipa.read_bytes()).hexdigest(),
            'minOSVersion': '17.4',
        }
        self.app = {
            'bundleIdentifier': tracker.BUNDLE_ID,
            'developerName': 'Riley Testut',
            'iconURL': 'https://example.invalid/icon.png',
            'versions': [self.version],
            'patreon': {'pledge': 3, 'hidden': True},
            'beta': True,
            'appPermissions': {'entitlements': [{'name': 'com.apple.developer.siri'}]},
        }
        self.feed = {'apps': [self.app]}

    def write_ipa(self):
        with zipfile.ZipFile(self.ipa, 'w', zipfile.ZIP_DEFLATED) as z:
            z.writestr('Payload/App.app/Info.plist', plistlib.dumps(self.info))
            z.writestr('Payload/App.app/App', executable({
                'application-identifier': 'TEAM.' + tracker.BUNDLE_ID,
                'com.apple.developer.team-identifier': 'TEAM',
                'com.apple.developer.siri': True,
            }))
            ext = dict(self.info, CFBundleIdentifier=tracker.BUNDLE_ID + '.Widget',
                       CFBundleExecutable='Widget')
            ext.pop('NSLocalNetworkUsageDescription')
            ext['NSCameraUsageDescription'] = 'Scan a code.'
            z.writestr('Payload/App.app/PlugIns/Widget.appex/Info.plist', plistlib.dumps(ext))
            z.writestr('Payload/App.app/PlugIns/Widget.appex/Widget', executable({
                'com.apple.security.application-groups': ['group.test'],
            }))

    def run_sync(self, ipa=True):
        return tracker.sync(self.feed, self.output, tracker.DEFAULT_REPOSITORY,
                            self.ipa if ipa else None)

    def test_verified_ipa_publishes_metadata_only(self):
        self.assertTrue(self.run_sync())
        data = json.loads(self.output.read_text())
        self.assertEqual(data['identifier'], 'io.github.famsyk.acbs-beta-track-repo')
        app = data['apps'][0]
        self.assertEqual(app['versions'][0]['buildVersion'], '100')
        self.assertNotIn('patreon', app)
        self.assertNotIn('beta', app)
        self.assertNotIn('marketplaceID', app)
        self.assertEqual(app['versions'][0]['downloadURL'], self.version['downloadURL'])

    def test_widget_entitlements_and_privacy_are_included(self):
        self.run_sync()
        p = json.loads(self.output.read_text())['apps'][0]['appPermissions']
        self.assertIn('com.apple.security.application-groups', p['entitlements'])
        self.assertEqual(p['privacy']['NSCameraUsageDescription'], 'Scan a code.')
        self.assertNotIn('application-identifier', p['entitlements'])

    def test_unchanged_hash_does_not_download(self):
        self.run_sync()
        with patch.object(tracker, 'fetch_to', side_effect=AssertionError('Unexpected network')):
            self.assertFalse(self.run_sync(ipa=False))

    def test_forced_verification_downloads_unchanged_ipa(self):
        self.run_sync()
        with patch.object(tracker, 'fetch_to', side_effect=lambda u, p, l: p.write_bytes(self.ipa.read_bytes())) as download:
            self.assertFalse(tracker.sync(self.feed, self.output, tracker.DEFAULT_REPOSITORY, verify_ipa=True))
            download.assert_called_once()

    def test_failed_forced_verification_preserves_source(self):
        self.run_sync()
        previous = self.output.read_bytes()
        with patch.object(tracker, 'fetch_to', side_effect=tracker.SyncError('Offline')):
            with self.assertRaises(tracker.SyncError):
                tracker.sync(self.feed, self.output, tracker.DEFAULT_REPOSITORY, verify_ipa=True)
        self.assertEqual(self.output.read_bytes(), previous)

    def test_metadata_only_change_is_updated_from_cache(self):
        self.run_sync()
        self.version['localizedDescription'] = 'New release note.'
        with patch.object(tracker, 'fetch_to', side_effect=AssertionError('Unexpected network')):
            self.assertTrue(self.run_sync(ipa=False))

    def test_next_beta_downloads_and_updates(self):
        self.run_sync()
        self.info['CFBundleVersion'] = '101'
        self.info['CFBundleShortVersionString'] = '3.0b11'
        self.write_ipa()
        self.version.update(version='3.0b11', date='2026-10-12T03:00:00Z',
                            size=self.ipa.stat().st_size,
                            sha256=hashlib.sha256(self.ipa.read_bytes()).hexdigest())
        with patch.object(tracker, 'fetch_to', side_effect=lambda u, p, l: p.write_bytes(self.ipa.read_bytes())) as download:
            self.assertTrue(self.run_sync(ipa=False))
            download.assert_called_once()
        self.assertEqual(json.loads(self.output.read_text())['apps'][0]['versions'][0]['buildVersion'], '101')

    def test_source_survives_bad_hash(self):
        self.run_sync()
        previous = self.output.read_bytes()
        self.version['sha256'] = '0' * 64
        with self.assertRaises(tracker.SyncError):
            self.run_sync()
        self.assertEqual(self.output.read_bytes(), previous)

    def test_source_survives_download_failure(self):
        self.run_sync()
        previous = self.output.read_bytes()
        self.version['sha256'] = '0' * 64
        with patch.object(tracker, 'fetch_to', side_effect=tracker.SyncError('Offline')):
            with self.assertRaises(tracker.SyncError):
                self.run_sync(ipa=False)
        self.assertEqual(self.output.read_bytes(), previous)

    def test_upstream_rollback_is_blocked(self):
        self.run_sync()
        self.version['date'] = '2026-01-01'
        with self.assertRaises(tracker.SyncError):
            self.run_sync()

    def test_first_entry_wins_not_string_sort(self):
        self.app['versions'].append(dict(self.version, version='3.0b9'))
        self.assertEqual(tracker.select_latest(self.feed)[1]['version'], '3.0b10')

    def test_duplicate_beta_entry_is_rejected(self):
        self.feed['apps'].append(copy.deepcopy(self.app))
        with self.assertRaises(tracker.SyncError):
            tracker.select_latest(self.feed)

    def test_stable_app_is_not_selected(self):
        self.feed['apps'].insert(0, dict(self.app, bundleIdentifier='com.rileytestut.AltStore'))
        self.assertEqual(tracker.select_latest(self.feed)[0]['bundleIdentifier'], tracker.BUNDLE_ID)

    def test_size_mismatch_is_rejected(self):
        self.version['size'] += 1
        with self.assertRaises(tracker.SyncError):
            self.run_sync()

    def test_ipa_version_mismatch_is_rejected(self):
        self.version['version'] = 'wrong'
        with self.assertRaises(tracker.SyncError):
            self.run_sync()

    def test_ipa_build_mismatch_is_rejected(self):
        self.version['buildVersion'] = '999'
        with self.assertRaises(tracker.SyncError):
            self.run_sync()

    def test_wrong_bundle_is_rejected(self):
        self.info['CFBundleIdentifier'] = 'com.example.other'
        self.write_ipa()
        self.version.update(size=self.ipa.stat().st_size, sha256=hashlib.sha256(self.ipa.read_bytes()).hexdigest())
        with self.assertRaises(tracker.SyncError):
            self.run_sync()

    def test_missing_hash_stops_tracking(self):
        self.version.pop('sha256')
        with self.assertRaises(tracker.SyncError):
            tracker.select_latest(self.feed)

    def test_authenticated_or_third_party_urls_are_rejected(self):
        urls = [
            'https://www.patreon.com/file?h=1&m=2',
            'https://cdn.altstore.io.evil.invalid/file/altstore/apps/altstore/x.ipa',
            'https://user:pass@cdn.altstore.io/file/altstore/apps/altstore/x.ipa',
            'http://cdn.altstore.io/file/altstore/apps/altstore/x.ipa',
            'https://cdn.altstore.io/file/altstore/apps/altstore/x.ipa?token=abc',
            'https://cdn.altstore.io/file/altstore/apps/altstore/../x.ipa',
            'https://cdn.altstore.io/file/altstore/apps/altstore/%2e%2e/x.ipa',
            'https://cdn.altstore.io:444/file/altstore/apps/altstore/x.ipa',
        ]
        for url in urls:
            with self.subTest(url=url), self.assertRaises(tracker.SyncError):
                tracker.public_url(url)

    def test_public_url_is_preserved(self):
        self.assertEqual(tracker.public_url(self.version['downloadURL']), self.version['downloadURL'])

    def test_patreon_only_latest_does_not_fall_back_silently(self):
        self.app['versions'].insert(0, dict(self.version, downloadURL='https://www.patreon.com/file?h=1&m=2'))
        with self.assertRaises(tracker.SyncError):
            tracker.select_latest(self.feed)

    def test_permissions_support_both_official_formats(self):
        p = tracker.normalize_permissions({
            'entitlements': ['a', {'name': 'b'}, 'a'],
            'privacy': [{'name': 'LocalNetwork', 'usageDescription': 'Find server'}],
        })
        self.assertEqual(p['entitlements'], ['a', 'b'])
        self.assertEqual(p['privacy'], {'NSLocalNetworkUsageDescription': 'Find server'})

    def test_os_requirement_is_not_lowered(self):
        self.version['minOSVersion'] = '18.0'
        self.run_sync()
        self.assertEqual(json.loads(self.output.read_text())['apps'][0]['versions'][0]['minOSVersion'], '18.0')

    def test_timezone_dates_are_compared_correctly(self):
        self.assertEqual(tracker.release_date('2026-10-11T12:00:00+09:00'),
                         tracker.release_date('2026-10-11T03:00:00Z'))

    def test_truncated_macho_is_rejected(self):
        with self.assertRaises(tracker.SyncError):
            tracker.macho_entitlements(b'\xcf\xfa\xed\xfe')

    def test_fat_macho_entitlements_are_read(self):
        thin = executable({'test.entitlement': True})
        fat = struct.pack('>II', 0xCAFEBABE, 1) + struct.pack('>IIIII', 0x100000C, 0, 28, len(thin), 0) + thin
        self.assertEqual(tracker.macho_entitlements(fat), {'test.entitlement'})

    def test_seed_source_has_expected_repository_and_version_fields(self):
        root = Path(__file__).resolve().parents[2]
        seed = json.loads((root / 'source.json').read_text())
        self.assertEqual(seed['identifier'], 'io.github.famsyk.acbs-beta-track-repo')
        version = seed['apps'][0]['versions'][0]
        for field in ('buildVersion', 'sha256', 'downloadURL', 'size'):
            self.assertIn(field, version)
        self.assertFalse((root / 'README.md').exists())


if __name__ == '__main__':
    unittest.main()
