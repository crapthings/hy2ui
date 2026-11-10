#!/usr/bin/env python3
"""Seal the local TUN app and bundled executables with the persistent Hy2UI certificate."""
import pathlib
import subprocess
import sys
from signing_identity import signing_context


# Signs nested code before sealing and strictly verifying the enclosing application bundle.
def main():
    if len(sys.argv) != 2 or not (pathlib.Path(sys.argv[1]) / 'Contents/MacOS').is_dir():
        raise SystemExit('Usage: Scripts/sign-local-app.sh Hy2UI.app')
    app = pathlib.Path(sys.argv[1])
    nested = sorted((app / 'Contents/Helpers').glob('*'))
    nested += sorted((app / 'Contents/MacOS').glob('*.dylib'))
    nested += sorted((app / 'Contents/Library/SystemExtensions').glob('*.systemextension'))
    with signing_context() as (fingerprint, keychain):
        for target in [*nested, app]:
            subprocess.run(['/usr/bin/codesign', '--force', '--sign', fingerprint,
                            '--keychain', keychain, '--timestamp=none', str(target)], check=True)
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    print('App sealed with persistent self-signing identity; Network Extension requires Apple signing.')


if __name__ == '__main__':
    main()
