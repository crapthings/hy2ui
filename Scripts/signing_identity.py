#!/usr/bin/env python3
"""Create or reuse a private, persistent self-signing identity outside the source checkout."""
import contextlib
import fcntl
import stat
import shlex
import datetime
import hashlib
import json
import os
import pathlib
import secrets
import shutil
import subprocess
import tempfile


# Runs signing tools without echoing private keys, keychain passwords or secret-bearing arguments.
def command(arguments):
    result = subprocess.run(arguments, capture_output=True)
    if result.returncode:
        raise SystemExit(f'{pathlib.Path(arguments[0]).name} failed (exit {result.returncode}); signing identity was not replaced.')
    return result.stdout


# Resolves the one user-private signing directory independently from application profiles and the repository.
def signing_directory():
    return pathlib.Path.home() / 'Library/Application Support/Hy2UI-Signing'


# Serializes identity setup and temporary keychain search-list changes across Hy2UI builds.
@contextlib.contextmanager
def signing_lock():
    lock = pathlib.Path.home() / 'Library/Application Support/.Hy2UI-Signing.lock'
    descriptor = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'w') as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        yield


# Rejects signing material that is missing, redirected or accessible to other users.
def check_private(path, directory=False):
    info = path.lstat()
    expected = stat.S_ISDIR if directory else stat.S_ISREG
    if not expected(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise SystemExit(f'Unsafe signing file permissions: {path}')


# Unlocks and validates the existing identity without silently replacing lost signing material.
def identity():
    directory = signing_directory()
    if not (directory / 'identity.json').exists():
        raise SystemExit('Run python3 Scripts/setup-signing.py once before building.')
    check_private(directory, directory=True)
    for name in ('identity.json', 'certificate.pem', 'keychain-password', 'signing.keychain-db'):
        check_private(directory / name)
    config = json.loads((directory / 'identity.json').read_text())
    der = command(['/usr/bin/openssl', 'x509', '-in', str(directory / 'certificate.pem'), '-outform', 'DER'])
    if config.get('version') != 1 or hashlib.sha1(der).hexdigest().upper() != config.get('sha1') or hashlib.sha256(der).hexdigest() != config.get('sha256'):
        raise SystemExit('Signing certificate does not match the saved identity; preserve the original signing files.')
    command(['/usr/bin/openssl', 'x509', '-in', str(directory / 'certificate.pem'), '-checkend', '0', '-noout'])
    keychain = directory / 'signing.keychain-db'
    password = (directory / 'keychain-password').read_text()
    command(['/usr/bin/security', 'unlock-keychain', '-p', password, str(keychain)])
    return config['sha1'], str(keychain)


# Makes the private key discoverable only during signing and restores the previous keychain search list.
@contextlib.contextmanager
def signing_context():
    with signing_lock():
        fingerprint, keychain = identity()
        previous = shlex.split(command(['/usr/bin/security', 'list-keychains', '-d', 'user']).decode())
        changed = keychain not in previous
        try:
            if changed:
                command(['/usr/bin/security', 'list-keychains', '-d', 'user', '-s', *previous, keychain])
            yield fingerprint, keychain
        finally:
            if changed:
                command(['/usr/bin/security', 'list-keychains', '-d', 'user', '-s', *previous])


# Installs a single self-signed code-signing identity without changing system trust or the default keychain.
def main():
    os.umask(0o077)
    directory = signing_directory()
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    check_private(directory, directory=True)
    if (directory / 'identity.json').exists():
        fingerprint, keychain = identity()
        print(f'Reusing Hy2UI self-signing identity: {fingerprint}')
        return
    if any(directory.iterdir()):
        raise SystemExit('Signing directory contains an incomplete identity. Preserve its files and resolve it before retrying.')
    openssl = shutil.which('openssl')
    if not openssl:
        raise SystemExit('OpenSSL is required to create the signing certificate.')
    password = secrets.token_urlsafe(48)
    with tempfile.TemporaryDirectory(prefix='hy2ui-signing-') as temporary:
        staging = pathlib.Path(temporary)
        private_key = staging / 'key.pem'
        certificate = staging / 'certificate.pem'
        export = staging / 'identity.p12'
        password_file = staging / 'password'
        password_file.write_text(password)
        config_file = staging / 'certificate.cnf'
        config_file.write_text('''[req]
prompt = no
distinguished_name = subject
x509_extensions = signing
[subject]
CN = Hy2UI Self Signing
O = Hy2UI
[signing]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
''')
        command([openssl, 'req', '-new', '-x509', '-newkey', 'rsa:3072', '-nodes', '-sha256',
                 '-days', '3650', '-config', str(config_file), '-keyout', str(private_key), '-out', str(certificate)])
        # macOS imports legacy PKCS#12 encryption reliably; the export remains protected by a random password.
        command([openssl, 'pkcs12', '-export', '-inkey', str(private_key), '-in', str(certificate),
                 '-name', 'Hy2UI Self Signing', '-out', str(export), '-passout', 'file:' + str(password_file),
                 '-keypbe', 'PBE-SHA1-3DES', '-certpbe', 'PBE-SHA1-3DES', '-macalg', 'sha1'])
        keychain = directory / 'signing.keychain-db'
        (directory / 'keychain-password').write_text(password)
        command(['/usr/bin/security', 'create-keychain', '-p', password, str(keychain)])
        command(['/usr/bin/security', 'set-keychain-settings', '-lut', '21600', str(keychain)])
        command(['/usr/bin/security', 'unlock-keychain', '-p', password, str(keychain)])
        command(['/usr/bin/security', 'import', str(export), '-k', str(keychain), '-P', password,
                 '-T', '/usr/bin/codesign'])
        command(['/usr/bin/security', 'set-key-partition-list', '-S', 'apple-tool:,apple:', '-s', '-k', password, str(keychain)])
        der = command([openssl, 'x509', '-in', str(certificate), '-outform', 'DER'])
        shutil.copyfile(certificate, directory / 'certificate.pem')
        shutil.copyfile(export, directory / 'identity-backup.p12')
        metadata = {'version': 1, 'sha1': hashlib.sha1(der).hexdigest().upper(),
                    'sha256': hashlib.sha256(der).hexdigest(), 'created': datetime.datetime.now(datetime.timezone.utc).isoformat()}
        (directory / 'identity.json').write_text(json.dumps(metadata, indent=2) + '\n')
        print('Created persistent self-signing identity:', metadata['sha1'])
        print('Private signing files:', directory)
        print('No system trust settings or application credentials were changed.')


if __name__ == '__main__':
    main()
