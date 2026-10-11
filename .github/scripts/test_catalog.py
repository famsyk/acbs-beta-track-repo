"""PAL compatibility regressions, including the reported missing-marketplace-ID error."""
import copy
import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import update_catalog as t


class CatalogTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.payload = b'official-test-variant'
        self.variant = {
            'assetPath': 'variant/00000000-0000-0000-0000-000000000001.ipa',
            'installTargets': [{'device': 'iPhone18,1', 'os': '26'}],
            'variantDetails': {'compressedSize': len(self.payload), 'hashes': [{
                'algorithm': 'sha256', 'chunkSize': 10,
                'encryptedChunkDigests': [hashlib.sha256(self.payload[i:i+10]).hexdigest()
                                         for i in range(0, len(self.payload), 10)]
            }]}
        }
        self.apps = []
        self.manifests = {}
        for spec, version, display, build in zip(t.APPS, ('2.3.13', '2.3.4'), ('2.3.3b', '2.3rc'), ('88', '63')):
            v = {'version': version, 'buildVersion': build, 'marketingVersion': display,
                 'date': '2026-10-11T00:00:00Z', 'minOSVersion': '17.4',
                 'downloadURL': f'https://altstore.io/adps/{spec.directory}/test/manifest.json', 'size': 20}
            self.apps.append({'bundleIdentifier': spec.listing, 'marketplaceID': spec.item,
                              'developerName': 'Riley & Shane', 'name': spec.name,
                              'iconURL': 'https://cdn.altstore.io/icon.png', 'localizedDescription': 'Test.',
                              'patreon': {'pledge': 3}, 'beta': True,
                              'appPermissions': {'entitlements': [], 'privacy': {}}, 'versions': [v]})
            self.manifests[spec.directory] = {
                'appleItemId': spec.item, 'bundleId': spec.actual,
                'shortVersionString': version, 'bundleVersion': build,
                'isLaunchProhibited': False, 'appInstallDeterminants': ['marketplace'],
                'variants': [copy.deepcopy(self.variant)]
            }
        self.feed = {'apps': self.apps}
        self.ipa = {'identifier': t.PREFIX, 'apps': [{'bundleIdentifier': t.APPS[1].listing,
                    'versions': [{'version': '2.3.1b', 'buildVersion': '67', 'date': '2026-10-12',
                                  'downloadURL': 'https://cdn.altstore.io/file/altstore/apps/altstore/2_3_1_b.ipa',
                                  'size': 40, 'sha256': 'f'*64}]}]}

    def download(self, url, limit=0):
        if url == t.UPSTREAM:
            return json.dumps(self.feed).encode()
        if url == t.classic.UPSTREAM:
            return b'{}'
        if url.endswith('/signature'):
            return b'official-signature-fixture'
        if '/variant/' in url:
            return self.payload
        for directory, manifest in self.manifests.items():
            if '/'+directory+'/' in url and url.endswith('/manifest.json'):
                return json.dumps(manifest).encode()
        raise AssertionError('Unexpected download: '+url)

    def refresh(self, force=False):
        def seed(feed, output, repository, **kwargs):
            output.write_text(json.dumps(self.ipa))
        with patch.object(t, 'download', side_effect=self.download), patch.object(t.classic, 'sync', side_effect=seed):
            t.refresh(self.root, force)

    def test_both_betas_in_main_and_alias(self):
        self.refresh()
        primary = t.load(self.root/'source.json')
        alias = t.load(self.root/'pal-source.json')
        self.assertEqual(primary['apps'], alias['apps'])
        self.assertEqual(len(primary['apps']), 2)
        t.validate_pal(primary)
        t.validate_pal(alias)

    def test_old_source_url_migrates_without_raw_ipa_rollback(self):
        (self.root/'source.json').write_text(json.dumps(self.ipa))
        self.refresh()
        primary = t.load(self.root/'source.json')
        self.assertEqual(primary['identifier'], t.PREFIX)
        self.assertEqual(primary['apps'][1]['versions'][0]['marketingVersion'], '2.3rc')

    def test_ipa_231b_is_separate_and_not_mislabelled(self):
        self.refresh()
        ipa = t.load(self.root/'classic-source.json')
        primary = t.load(self.root/'source.json')
        self.assertEqual(ipa['identifier'], t.PREFIX+'.classic-ipa')
        self.assertEqual(ipa['apps'][0]['versions'][0]['version'], '2.3.1b')
        self.assertEqual(primary['apps'][1]['versions'][0]['version'], '2.3.4')
        self.assertNotIn('marketplaceID', ipa['apps'][0])
        self.assertIn('2.3.1b', primary['apps'][1]['localizedDescription'])

    def test_identities_preserved_for_both_existing_endpoints(self):
        self.refresh()
        self.assertEqual(t.load(self.root/'source.json')['identifier'], t.PREFIX)
        self.assertEqual(t.load(self.root/'pal-source.json')['identifier'], t.PREFIX+'.pal')

    def test_latest_classic_pal_adp_can_advance_independently(self):
        self.refresh()
        v = self.apps[1]['versions'][0]
        v.update(version='2.3.6', buildVersion='67', marketingVersion='2.3.1b', date='2026-10-12')
        self.manifests[t.APPS[1].directory].update(shortVersionString='2.3.6', bundleVersion='67')
        self.refresh()
        self.assertEqual(t.load(self.root/'source.json')['apps'][1]['versions'][0]['marketingVersion'], '2.3.1b')

    def test_missing_marketplace_id_rejected_for_either_app(self):
        for i in range(2):
            source = copy.deepcopy(self.feed)
            source['apps'][i].pop('marketplaceID')
            with self.assertRaises(ValueError):
                t.validate_pal(source)

    def test_adding_id_to_raw_ipa_does_not_make_it_a_pal_adp(self):
        source = copy.deepcopy(self.feed)
        source['apps'][1]['versions'][0]['downloadURL'] = self.ipa['apps'][0]['versions'][0]['downloadURL']
        with self.assertRaises(ValueError):
            t.validate_pal(source)

    def test_duplicate_and_missing_listings_rejected(self):
        for apps in (self.apps[:1], self.apps+self.apps[:1], [self.apps[0], self.apps[0]]):
            with self.assertRaises(ValueError):
                t.validate_pal({'apps': apps})

    def test_missing_build_rejected(self):
        self.apps[1]['versions'][0].pop('buildVersion')
        with self.assertRaises(ValueError):
            t.select(self.feed, t.APPS[1])

    def test_manifest_fields_checked_for_both(self):
        for spec in t.APPS:
            _, version, _ = t.select(self.feed, spec)
            manifest = self.manifests[spec.directory]
            t.verify_manifest(manifest, version, spec)
            for key in ('appleItemId', 'bundleId', 'shortVersionString', 'bundleVersion'):
                with self.subTest(app=spec.name, key=key), self.assertRaises(ValueError):
                    t.verify_manifest(dict(manifest, **{key: 'wrong'}), version, spec)

    def test_only_pal_itself_may_have_different_listing_bundle(self):
        spec = t.APPS[1]
        manifest = self.manifests[spec.directory]
        manifest['bundleId'] = 'com.rileytestut.AltStore'
        with self.assertRaises(ValueError):
            t.verify_manifest(manifest, self.apps[1]['versions'][0], spec)

    def test_denied_launch_or_wrong_distribution_rejected(self):
        manifest = self.manifests[t.APPS[0].directory]
        for override in ({'isLaunchProhibited': True}, {'appInstallDeterminants': ['website']}, {'variants': []}):
            with self.assertRaises(ValueError):
                t.verify_manifest(dict(manifest, **override), self.apps[0]['versions'][0], t.APPS[0])

    def test_variant_size_and_complete_chunk_hashes(self):
        self.assertEqual(t.verify_variant(self.payload, self.variant), hashlib.sha256(self.payload).hexdigest())
        for data in (self.payload+b'x', b'x'+self.payload[1:]):
            with self.assertRaises(ValueError):
                t.verify_variant(data, self.variant)

    def test_invalid_chunk_size_rejected(self):
        for size in (0, True, t.LIMIT+1):
            self.variant['variantDetails']['hashes'][0]['chunkSize'] = size
            with self.assertRaises(ValueError):
                t.verify_variant(self.payload, self.variant)

    def test_latest_iphone_variant_selected(self):
        newer = copy.deepcopy(self.variant)
        newer['installTargets'][0]['os'] = '27'
        self.assertIs(t.choose_variant({'variants': [self.variant, newer]}), newer)
        with self.assertRaises(ValueError):
            t.choose_variant({'variants': []})

    def test_paths_and_authenticated_urls_rejected(self):
        for url in ('http://altstore.io/a', 'https://evil.invalid/a', 'https://altstore.io/a?key=x',
                    'https://u:p@altstore.io/a', 'https://altstore.io/a/../b', 'https://altstore.io/%2e%2e/x'):
            with self.subTest(url=url), self.assertRaises(ValueError):
                t.public_url(url)
        with self.assertRaises(ValueError):
            t.variant_path({'assetPath': '../payload.ipa'})

    def test_manifest_suffix_normalized(self):
        base = 'https://altstore.io/adps/altstore-classic/2_3_rc'
        self.assertEqual(t.base_url(base+'/manifest.json', t.APPS[1]), base)
        with self.assertRaises(ValueError):
            t.base_url(base, t.APPS[0])

    def test_date_and_build_rollback_rejected(self):
        old = self.apps[1]
        v = old['versions'][0]
        for change in ({'date': '2026-01-01'}, {'buildVersion': '62'}):
            with self.assertRaises(ValueError):
                t.prevent_rollback(old, dict(v, **change))

    def test_upstream_failure_keeps_all_outputs(self):
        self.refresh()
        before = {name: (self.root/name).read_bytes() for name in t.OUTPUTS}
        self.manifests[t.APPS[1].directory]['appleItemId'] = 'wrong'
        with self.assertRaises(ValueError):
            self.refresh()
        self.assertEqual(before, {name: (self.root/name).read_bytes() for name in t.OUTPUTS})

    def test_cached_sample_hash_reused_and_force_rechecks(self):
        self.refresh()
        self.payload = b'bad-size'
        self.refresh()
        with self.assertRaises(ValueError):
            self.refresh(force=True)

    def test_display_permissions_and_regions_preserved(self):
        app = dict(self.apps[1], _regions={'exclude': ['test-region']})
        result = t.listing(app, app['versions'][0], t.APPS[1], '2.3.1b')
        self.assertEqual(result['appPermissions'], app['appPermissions'])
        self.assertEqual(result['_regions'], app['_regions'])
        self.assertEqual(result['versions'][0]['marketingVersion'], '2.3rc')
        self.assertNotIn('patreon', result)
        self.assertNotIn('beta', result)

    def test_user_info_values_are_strings(self):
        self.refresh()
        info = t.load(self.root/'source.json')['userInfo']
        self.assertTrue(all(isinstance(v, str) for v in info.values()))
        self.assertEqual(info['deviceInstallation'], 'not-tested')


if __name__ == '__main__':
    unittest.main()
