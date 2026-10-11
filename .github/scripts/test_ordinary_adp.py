"""Ordinary notarized apps differ from marketplace apps in Apple's ADP schema."""
import unittest
import update_catalog as t


class OrdinaryADPTests(unittest.TestCase):
    def test_classic_accepts_empty_install_determinants(self):
        spec = t.APPS[1]
        version = {'version': '2.3.4', 'buildVersion': '63'}
        manifest = {'appleItemId': spec.item, 'bundleId': spec.actual,
                    'shortVersionString': '2.3.4', 'bundleVersion': '63',
                    'isLaunchProhibited': False, 'appInstallDeterminants': [], 'variants': [{}]}
        t.verify_manifest(manifest, version, spec)
        manifest['appInstallDeterminants'] = 'marketplace'
        with self.assertRaises(ValueError):
            t.verify_manifest(manifest, version, spec)

    def test_classic_manifest_url_is_exported_as_adp_base(self):
        spec = t.APPS[1]
        base = 'https://altstore.io/adps/altstore-classic/2_3_rc'
        app = {'bundleIdentifier': spec.listing, 'marketplaceID': spec.item}
        version = {'version': '2.3.4', 'buildVersion': '63', 'downloadURL': base+'/manifest.json'}
        result = t.listing(app, version, spec, '2.3.1b')
        self.assertEqual(result['versions'][0]['downloadURL'], base)
        self.assertEqual(version['downloadURL'], base+'/manifest.json')


if __name__ == '__main__':
    unittest.main()
