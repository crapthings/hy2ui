#!/usr/bin/env python3
"""Compile reviewed installer sources into the app instead of executing a writable script file."""
import base64
import pathlib


# Generates immutable Swift string payloads from the same scripts used for manual recovery.
def main():
    root = pathlib.Path(__file__).resolve().parent.parent
    output = root / '.build/generated/HelperInstallerPayload.swift'
    output.parent.mkdir(parents=True, exist_ok=True)
    declarations = []
    for operation in ['install', 'uninstall']:
        source = root / f'Scripts/{operation}-local-tun-helper.sh'
        encoded = base64.b64encode(source.read_bytes()).decode('ascii')
        declarations.append(f'    static let {operation} = "{encoded}"')
    text = ('import Foundation\n\n'
            '/// Stores the reviewed installer programs inside the signed application executable.\n'
            'enum HelperInstallerPayload {\n' + '\n'.join(declarations) + '\n}\n')
    if not output.exists() or output.read_text() != text:
        output.write_text(text)


if __name__ == '__main__':
    main()
