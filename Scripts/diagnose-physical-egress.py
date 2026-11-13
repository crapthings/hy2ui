#!/usr/bin/env python3
"""Probe Darwin interface-bound TCP/DNS sockets without changing routes, DNS or TUN.

Run once with the intended capture active. This exercises Darwin's binding
primitives, not the complete Rust Fake DNS implementation. No unbound retry occurs.
"""
import argparse
import concurrent.futures
import ipaddress
import json
import os
import re
import secrets
import socket
import struct
import subprocess
import sys
import tempfile
import time


# Reads bounded command output; these commands only inspect routing/interface state.
def command(arguments):
    try:
        result = subprocess.run(arguments, capture_output=True, text=True, timeout=3)
        return result.returncode, result.stdout
    except subprocess.TimeoutExpired:
        return 124, ''


# Returns the selected interface from an unscoped or explicitly scoped route lookup.
def route_to(address, interface=None):
    family = '-inet6' if ':' in address else '-inet'
    arguments = ['/sbin/route', '-n', 'get', family]
    if interface:
        arguments += ['-ifscope', interface]
    code, output = command(arguments + [address])
    match = re.search(r'^\s*interface:\s*(\S+)', output, re.M)
    return {'exit': code, 'interface': match.group(1) if match else None}


# Reads exactly one DNS TCP message without interpreting application or account data.
def receive_exact(stream, count):
    data = bytearray()
    while len(data) < count:
        part = stream.recv(count - len(data))
        if not part:
            raise OSError('DNS connection closed before complete reply')
        data.extend(part)
    return bytes(data)


# Opens, verifies and probes one interface-bound socket; errors never trigger unbound fallback.
def probe(interface, index, local_addresses, address, protocol):
    family = socket.AF_INET6 if ':' in address else socket.AF_INET
    level, option = (socket.IPPROTO_IPV6, 125) if family == socket.AF_INET6 else (socket.IPPROTO_IP, 25)
    # Darwin SDK: IP_BOUND_IF=25, IPV6_BOUND_IF=125. Python does not export these constants.
    result = {'target': address, 'protocol': protocol, 'bound_verified': False, 'success': False,
              'ordinary_route': route_to(address), 'scoped_route': route_to(address, interface)}
    start = time.monotonic()
    try:
        with socket.socket(family, socket.SOCK_DGRAM if protocol == 'dns-udp' else socket.SOCK_STREAM) as stream:
            stream.settimeout(3)
            stream.setsockopt(level, option, index)
            if stream.getsockopt(level, option) != index:
                raise OSError('Interface binding could not be verified')
            result['bound_verified'] = True
            stream.connect((address, 443 if protocol == 'tcp' else 53))
            source = str(ipaddress.ip_address(stream.getsockname()[0].split('%')[0]))
            result['source'] = source
            result['source_on_interface'] = source in local_addresses
            if not result['source_on_interface']:
                raise OSError('Socket source does not match the requested interface')
            if protocol != 'tcp':
                identity = secrets.randbelow(65536)
                question = b'\x07example\x03com\x00\x00\x01\x00\x01'
                query = struct.pack('!6H', identity, 0x0100, 1, 0, 0, 0) + question
                if protocol == 'dns-tcp':
                    stream.sendall(struct.pack('!H', len(query)) + query)
                    length = struct.unpack('!H', receive_exact(stream, 2))[0]
                    response = receive_exact(stream, length)
                else:
                    stream.send(query)
                    response = stream.recv(65535)
                if len(response) < 12:
                    raise OSError('DNS reply too short')
                reply_id, flags, questions, answers, _, _ = struct.unpack('!6H', response[:12])
                if reply_id != identity or not flags & 0x8000 or flags & 0x020f or questions != 1 or answers == 0 or response[12:12 + len(question)] != question:
                    raise OSError('DNS reply identity, status or question could not be verified')
            if result['scoped_route']['interface'] != interface:
                raise OSError('Scoped routing inspection did not confirm the requested interface')
            result['success'] = True
    except OSError as error:
        result['error'] = str(error)
        result['errno'] = error.errno
    result['elapsed_ms'] = round((time.monotonic() - start) * 1000, 2)
    return result


# Writes a private, credential-free diagnostic report without changing system networking.
def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--interface', required=True)
    parser.add_argument('--label', default='hy2ui')
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('macOS only')
    if not re.fullmatch(r'[A-Za-z0-9_.-]{1,15}', args.interface) or args.interface.startswith(('lo', 'utun', 'tun', 'tap', 'ppp', 'ipsec', 'awdl', 'llw', 'gif', 'stf')):
        parser.error('select a non-capture physical egress interface')
    index = socket.if_nametoindex(args.interface)
    code, output = command(['/sbin/ifconfig', args.interface])
    if code or not re.search(r'flags=.*<[^>]*\bUP\b', output):
        parser.error('interface could not be verified as up')
    addresses = set()
    for value in re.findall(r'^\s*inet6?\s+([0-9a-fA-F:.%a-zA-Z0-9]+)', output, re.M):
        addresses.add(str(ipaddress.ip_address(value.split('%')[0])))
    jobs = [(address, protocol) for address in ['1.1.1.1', '2606:4700:4700::1111'] for protocol in ['tcp', 'dns-tcp', 'dns-udp']]
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        results = list(pool.map(lambda job: probe(args.interface, index, addresses, *job), jobs))
    try:
        identity_unchanged = socket.if_nametoindex(args.interface) == index
    except OSError:
        identity_unchanged = False
    report = {'schema_version': 1, 'label': args.label, 'interface': args.interface,
              'interface_index': index, 'identity_unchanged': identity_unchanged, 'results': results,
              'note': 'Success while ordinary_route points at the active TUN is evidence for physical egress bypass. A connection failure alone does not identify recursion; firewall, ISP filtering or missing IPv6 can also fail. No routes, DNS settings or services are changed.'}
    descriptor, path = tempfile.mkstemp(prefix='hy2ui-physical-egress-', suffix='.json')
    with os.fdopen(descriptor, 'w') as handle:
        json.dump(report, handle, indent=2)
        handle.write('\n')
    print(path)
    for result in results:
        print(result['target'], result['protocol'], 'bound=' + str(result['bound_verified']),
              'success=' + str(result['success']), 'ordinary=' + str(result['ordinary_route']['interface']),
              'scoped=' + str(result['scoped_route']['interface']))


if __name__ == '__main__':
    main()
