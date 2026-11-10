"""Check diagnostic privacy and address-family probes without making network requests."""
import importlib.util
import json
import pathlib
import unittest
from unittest.mock import patch

# Loads the command-line diagnostic module without executing its network checks.
spec = importlib.util.spec_from_file_location('diagnostics', pathlib.Path(__file__).resolve().parents[2] / 'Scripts/diagnose-network.py')
diagnostics = importlib.util.module_from_spec(spec)
spec.loader.exec_module(diagnostics)


# Prevents reports from exposing proxy passwords or unrelated process environment data.
class DiagnosticPrivacyTests(unittest.TestCase):
    def test_process_report_excludes_credentials(self):
        command = 'codex --no-daemon HTTPS_PROXY=http://name:private-password@127.0.0.1:18080 UNRELATED_TOKEN=private-token'
        with patch.object(diagnostics, 'matching_processes', return_value=['123 /usr/local/bin/codex']), patch.object(
                diagnostics, 'run', return_value={'stdout': command}):
            records = diagnostics.process_state()
        encoded = json.dumps(records)
        self.assertNotIn('private-password', encoded)
        self.assertNotIn('private-token', encoded)
        self.assertNotIn('name:', encoded)
        self.assertEqual(records[0]['proxies']['HTTPS_PROXY'], {'scheme': 'http', 'host': '127.0.0.1', 'port': 18080})
        self.assertTrue(records[0]['no_daemon_argument'])

    def test_ipv6_probe_pins_destination_and_keeps_tls_verification(self):
        target = ('ipv6', 'https://www.google.com/generate_204', False,
                  ['--ipv6', '--resolve', 'www.google.com:443:[2001:db8::1]'])
        with patch.object(diagnostics, 'run', return_value={'exit': 0}) as run:
            diagnostics.probe(target)
        command, environment = run.call_args.args
        self.assertIn('--ipv6', command)
        self.assertIn('www.google.com:443:[2001:db8::1]', command)
        self.assertNotIn('--insecure', command)
        self.assertNotIn('-k', command)
        self.assertTrue(all(key.lower() not in ['http_proxy', 'https_proxy', 'all_proxy', 'no_proxy'] for key in environment))


if __name__ == '__main__':
    unittest.main()
