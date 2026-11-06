import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
def module(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / file)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result

render = module('mail_render', 'services/mail/render.py')
config = module('mail_config', 'services/mail/stalwart/init.py')

class MailConfigTest(unittest.TestCase):
    def test_renderer_keeps_public_host_and_mailbox_domain_distinct(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, {
            'MAIL_DOMAIN': 'mail.ifkafin.com', 'STALWART_DEFAULT_DOMAIN': 'heylomeet.com',
            'WEBMAIL_DOMAIN': 'https://webmail.ifkafin.com',
        }, clear=True):
            file = Path(tmp) / '.env'
            render.write_env(file)
            values = dict(line.split('=', 1) for line in file.read_text().splitlines())
            self.assertEqual(json.loads(values['STALWART_HOSTNAME']), 'mail.ifkafin.com')
            self.assertEqual(json.loads(values['STALWART_DEFAULT_DOMAIN']), 'heylomeet.com')
            self.assertEqual(json.loads(values['BULWARK_JMAP_SERVER_URL']), 'https://mail.ifkafin.com')
            self.assertEqual(json.loads(values['STALWART_HTTP_CORS_ALLOWED_ORIGINS']), 'https://webmail.ifkafin.com')
            self.assertIn('GARAGE_IMAGE', values)
            self.assertFalse(any('MINIO' in k for k in values))

    def test_safe_plan_uses_current_http_schema(self):
        with patch.dict(os.environ, {'STALWART_HOSTNAME':'mail.ifkafin.com',
                                     'STALWART_HTTP_CORS_ALLOWED_ORIGINS':'https://webmail.ifkafin.com'}, clear=True):
            plan = config.apply_plan()
        self.assertTrue(all(x['@type'] == 'update' for x in plan))
        self.assertFalse(any(x['object'] in ('Bootstrap','BlobStore','NetworkListener') for x in plan))
        http = next(x['value'] for x in plan if x['object'] == 'Http')
        self.assertNotIn('useXForwarded', http)
        self.assertEqual(http['clientIpSource'], 'xForwardedFor')
        self.assertEqual(http['responseHeaders']['Access-Control-Allow-Origin'], 'https://webmail.ifkafin.com')
        self.assertIn('OPTIONS', http['responseHeaders']['Access-Control-Allow-Methods'])
        self.assertFalse(http['usePermissiveCors'])

    def test_bootstrap_uses_garage_file_credentials(self):
        with tempfile.TemporaryDirectory() as tmp:
            key = Path(tmp) / 'access-key'
            key.write_text('test-public-key')
            output = Path(tmp) / 'config'
            with patch.dict(os.environ, {'STALWART_S3_ACCESS_KEY_FILE':str(key)}, clear=True), patch.object(config, 'CONFIG_DIR', output), patch('os.chown'):
                config.main()
                pointer = output / 'config.json'
                pointer.write_text('existing datastore pointer')
                config.main()
                self.assertEqual(pointer.read_text(), 'existing datastore pointer')
                pointer.unlink()
            self.assertFalse((output/'config.json').exists())
            self.assertTrue((output/'datastore.json').exists())
            bootstrap = json.loads((output/'bootstrap.json').read_text())
            self.assertEqual(bootstrap['blobStore']['@type'], 'S3')
            self.assertEqual(bootstrap['inMemoryStore']['url'], 'redis://:stalwart@stalwart-redis:6379/0')
            self.assertEqual(bootstrap['blobStore']['region']['url'], 'http://stalwart-garage:3900')
            self.assertEqual(bootstrap['blobStore']['accessKeyId']['value'], 'test-public-key')
            self.assertEqual(bootstrap['blobStore']['secretKey']['@type'], 'File')

if __name__ == '__main__':
    unittest.main()
