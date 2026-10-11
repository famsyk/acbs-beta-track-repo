import copy
import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import update_pal_source as tracker


class PALTrackerTests(unittest.TestCase):
    def setUp(self):
        self.version = {
            'version': '2.3.13', 'buildVersion': '88',
            'date': '2026-06-23T17:00:00-04:00',
            'downloadURL': 'https://altstore.io/adps/altstore/2_3_3_b',
            'size': 10, 'minOSVersion': '17.4', 'marketingVersion': '2.3.3b (88)'
        }
        self.app = {
            'bundleIdentifier': tracker.BETA_ID,
            'marketplaceID': tracker.MARKETPLACE_ID,
            'patreon': {'pledge': 3}, 'versions': [self.version],
            'appPermissions': {'entitlements': ['com.apple.developer.marketplace.app-installation']}
        }
        self.payload = b'public-official-test-fixture'
        self.variant = {
            'assetPath': 'variant/00000000-0000-0000-0000-000000000001.ipa',
            'installTargets': [{'device': 'iPhone18,1', 'os': '26'}],
            'variantDetails': {'compressedSize': len(self.payload), 'hashes': [{
                'algorithm': 'sha256', 'chunkSize': 10,
                'encryptedChunkDigests': [hashlib.sha256(self.payload[i:i+10]).hexdigest() for i in range(0, len(self.payload), 10)]
            }]}
        }
        self.manifest = {
            'appleItemId': tracker.MARKETPLACE_ID, 'bundleId': tracker.ACTUAL_ID,
            'shortVersionString': self.version['version'], 'bundleVersion': '88',
            'isLaunchProhibited': False, 'appInstallDeterminants': ['marketplace'],
            'variants': [self.variant]
        }

    def test_pal_selected_not_classic(self):
        upstream = {'apps': [{'bundleIdentifier': 'com.rileytestut.AltStore.Beta'}, self.app]}
        app, version, base = tracker.select_beta(upstream)
        self.assertEqual(app['bundleIdentifier'], tracker.BETA_ID)
        self.assertEqual(base, self.version['downloadURL'])

    def test_duplicate_beta_rejected(self):
        with self.assertRaises(ValueError):
            tracker.select_beta({'apps': [self.app, self.app]})

    def test_untrusted_and_authenticated_urls_rejected(self):
        for url in ('http://altstore.io/file', 'https://example.com/file', 'https://www.patreon.com/posts/1', 'https://user:password@altstore.io/file', 'https://altstore.io/file?token=secret'):
            with self.subTest(url=url), self.assertRaises(ValueError):
                tracker.require_url(url)

    def test_manifest_identifiers_and_build_are_checked(self):
        tracker.verify_manifest(self.manifest, self.version)
        for key in ('appleItemId', 'bundleId', 'shortVersionString', 'bundleVersion'):
            candidate = dict(self.manifest, **{key: 'wrong'})
            with self.subTest(key=key), self.assertRaises(ValueError):
                tracker.verify_manifest(candidate, self.version)

    def test_prohibited_launch_rejected(self):
        self.manifest['isLaunchProhibited'] = True
        with self.assertRaises(ValueError):
            tracker.verify_manifest(self.manifest, self.version)

    def test_unsafe_asset_path_rejected(self):
        self.variant['assetPath'] = '../manifest.json'
        with self.assertRaises(ValueError):
            tracker.asset_path(self.variant)

    def test_chunk_hash_and_size_verified(self):
        self.assertEqual(tracker.verify_variant(self.payload, self.variant), hashlib.sha256(self.payload).hexdigest())
        for data in (self.payload+b'x', b'x'+self.payload[1:]):
            with self.assertRaises(ValueError):
                tracker.verify_variant(data, self.variant)

    def test_latest_iphone_os_variant_selected(self):
        older = copy.deepcopy(self.variant)
        older['installTargets'] = [{'device': 'iPhone18,1', 'os': '18'}]
        self.manifest['variants'].insert(0, older)
        self.assertIs(tracker.select_iphone_variant(self.manifest), self.variant)

    def test_source_identity_permissions_and_display_are_preserved(self):
        source = tracker.make_source(self.app, self.version, {})
        self.assertNotIn('patreon', source['apps'][0])
        self.assertEqual(source['apps'][0]['marketplaceID'], tracker.MARKETPLACE_ID)
        self.assertEqual(source['apps'][0]['appPermissions'], self.app['appPermissions'])
        self.assertEqual(source['apps'][0]['versions'][0]['marketingVersion'], '2.3.3b (88)')
        self.assertIn('PAL', source['name'])

    def test_rollback_rejected(self):
        source = tracker.make_source(self.app, self.version, {})
        older = dict(self.version, date='2026-06-22T17:00:00-04:00')
        with self.assertRaises(ValueError):
            tracker.prevent_rollback(source, older)

    def test_failed_download_preserves_existing_source(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)/'pal-source.json'
            original = json.dumps(tracker.make_source(self.app, self.version, {}))
            path.write_text(original)
            with mock.patch.object(tracker, 'OUTPUT', path), mock.patch.object(tracker, 'download', side_effect=OSError('offline')):
                with self.assertRaises(OSError):
                    tracker.main()
            self.assertEqual(path.read_text(), original)


if __name__ == '__main__':
    unittest.main()
