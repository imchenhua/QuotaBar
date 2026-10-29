import importlib.util
import io
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('importer', Path(__file__).parents[1] / 'quotabar-import.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class ImportTests(unittest.TestCase):
    def test_missing_cookie_retains_account(self):
        registry = '{"accounts":{"1":{"email":"a@example.com","organizationUuid":"org","nickname":"A"}}}'
        with patch.object(Path, 'read_text', return_value=registry), patch.object(module, 'profile_map', return_value={}):
            result = module.export_accounts()
        self.assertEqual(result, [{'name':'A', 'email':'a@example.com', 'org':'org', 'sessionKey':''}])

    def test_domain_must_match_exactly(self):
        registry = '{"accounts":{"1":{"email":"a","organizationUuid":"o","nickname":"A"}}}'
        with patch.object(Path, 'read_text', return_value=registry), patch.object(module, 'profile_map', return_value={'a|o':'profile'}), patch.object(module, 'load_cookies', return_value=[{'name':'sessionKey','value':'fake','domain':'evilclaude.ai'}]):
            self.assertEqual(module.export_accounts()[0]['sessionKey'], '')

    def test_default_invocation_never_exports_secrets(self):
        with patch.object(module.sys, 'argv', ['importer']), patch.object(module.sys, 'stderr', io.StringIO()), patch.object(module.sys, 'stdout', io.StringIO()) as output:
            self.assertEqual(module.main(), 2)
            self.assertEqual(output.getvalue(), '')

if __name__ == '__main__': unittest.main()
