#!/usr/bin/env python3
"""Verify that distinct executable versions retain the same certificate-bound designated requirement."""
import pathlib
import subprocess
import tempfile
from signing_identity import signing_context


# Builds two different probes and checks stable identity, changed code hashes and restored keychain state.
def main():
    before = subprocess.check_output(['security', 'list-keychains', '-d', 'user'])
    requirements = []
    hashes = []
    with tempfile.TemporaryDirectory(prefix='hy2ui-signing-test-') as temporary:
        directory = pathlib.Path(temporary)
        with signing_context() as (fingerprint, keychain):
            for version in (0, 1):
                source = directory / 'probe.c'
                executable = directory / 'probe'
                source.write_text(f'int main(void) {{ return {version}; }}\n')
                subprocess.run(['clang', str(source), '-o', str(executable)], check=True)
                subprocess.run(['codesign', '--force', '--sign', fingerprint, '--keychain', keychain,
                                '--identifier', 'dev.hy2ui.signing-test', '--timestamp=none', str(executable)], check=True)
                subprocess.run(['codesign', '--verify', '--strict', str(executable)], check=True)
                details = subprocess.run(['codesign', '-d', '-r-', '--verbose=4', str(executable)],
                                         capture_output=True, text=True, check=True)
                details = details.stdout + details.stderr
                requirements.append(next(line for line in details.splitlines() if 'designated =>' in line))
                hashes.append(next(line for line in details.splitlines() if line.startswith('CDHash=')))
    assert requirements[0] == requirements[1], 'Designated requirement changed between versions'
    assert 'certificate' in requirements[0] and 'cdhash' not in requirements[0], 'Identity must bind the certificate'
    assert hashes[0] != hashes[1], 'Probe versions must contain different code'
    assert subprocess.check_output(['security', 'list-keychains', '-d', 'user']) == before, 'Keychain search list was not restored'
    print('PASS: different builds share a certificate-bound identity; keychain search list restored.')


if __name__ == '__main__':
    main()
