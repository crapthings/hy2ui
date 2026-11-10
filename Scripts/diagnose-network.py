#!/usr/bin/env python3
"""Record bounded, credential-free network evidence without modifying system configuration."""
import concurrent.futures
import datetime
import ipaddress
import json
import os
import pathlib
import re
import socket
import subprocess
import time
import urllib.parse


# Runs one read-only diagnostic with a bounded duration and output size.
def run(arguments, environment=None):
    try:
        result = subprocess.run(arguments, capture_output=True, text=True, timeout=15, env=environment)
        return {'exit': result.returncode, 'stdout': result.stdout[:24000], 'stderr': result.stderr[:2000]}
    except subprocess.TimeoutExpired:
        return {'error': 'diagnostic timed out'}


# Selects exact process names before truncating output so late PIDs are not missed on busy machines.
def matching_processes(names):
    pids = []
    for name in names:
        result = run(['/usr/bin/pgrep', '-x', name])
        pids.extend(value for value in result.get('stdout', '').splitlines() if value.isdecimal())
    if not pids:
        return []
    result = run(['/bin/ps', '-p', ','.join(pids), '-o', 'pid=,comm='])
    return result.get('stdout', '').splitlines()


# Exposes only sanitized proxy destinations instead of process arguments or credentials.
def process_state():
    records = []
    for line in matching_processes(['codex']):
        if not line.strip().endswith('codex'):
            continue
        pid = line.split()[0]
        raw = run(['/bin/ps', 'eww', '-p', pid, '-o', 'command=']).get('stdout', '')
        proxies = {}
        for key, value in re.findall(r'(?:^|\s)((?:HTTP|HTTPS|ALL)_PROXY|(?:http|https|all)_proxy)=([^\s]*)', raw):
            try:
                url = urllib.parse.urlsplit(value)
                proxies[key] = {'scheme': url.scheme, 'host': url.hostname, 'port': url.port}
            except ValueError:
                proxies[key] = {'error': 'invalid URL'}
        records.append({'pid': int(pid), 'no_daemon_argument': '--no-daemon' in raw, 'proxies': proxies})
    return records


# Checks unauthenticated transport only, explicitly bypassing proxy environment variables.
def probe(target):
    name, url, upgrade, *options = target
    environment = {key: value for key, value in os.environ.items() if key.lower() not in
                   ('http_proxy', 'https_proxy', 'all_proxy', 'no_proxy')}
    command = ['/usr/bin/curl', '--noproxy', '*', '--http1.1', '--connect-timeout', '5',
               '--max-time', '10', '--silent', '--show-error', '--output', '/dev/null',
               '--write-out', 'http=%{http_code} peer=%{remote_ip} tls=%{ssl_verify_result} connect=%{time_connect} total=%{time_total}']
    if upgrade:
        command += ['--header', 'Connection: Upgrade', '--header', 'Upgrade: websocket',
                    '--header', 'Sec-WebSocket-Version: 13',
                    '--header', 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==']
    if options:
        command.extend(options[0])
    command.append(url)
    return name, run(command, environment)


# Checks IP-only TCP handshakes without treating local TUN acceptance as remote target success.
def direct_transport(target):
    name, family, host = target
    started = time.monotonic()
    try:
        with socket.socket(family, socket.SOCK_STREAM) as connection:
            connection.settimeout(5)
            connection.connect((host, 443))
        return name, {'connected': True, 'tcp_handshake_only': True, 'milliseconds': round((time.monotonic() - started) * 1000)}
    except OSError as error:
        return name, {'connected': False, 'errno': error.errno, 'error': type(error).__name__}


# Saves a portable report while preserving the network state that the user chose.
def main():
    timestamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    report = {'timestamp': timestamp,
              'scope': 'No credentials or authenticated API calls. HTTP 401/403 does not prove authenticated WebSocket success. A TCP handshake may terminate in the local TUN stack and does not prove remote target reachability; use HTTPS results.',
              'codex': process_state()}
    checks = {'system_proxy': ['/usr/sbin/scutil', '--proxy'],
              'dns': ['/usr/sbin/scutil', '--dns'],
              'routes_ipv4': ['/usr/sbin/netstat', '-rn', '-f', 'inet'],
              'routes_ipv6': ['/usr/sbin/netstat', '-rn', '-f', 'inet6'],
              'chatgpt_dns': ['/usr/bin/dscacheutil', '-q', 'host', '-a', 'name', 'chatgpt.com'],
              'google_dns_aaaa': ['/usr/bin/dig', '+short', '+time=3', '+tries=1', '@1.1.1.1', 'www.google.com', 'AAAA'],
              'dns_udp': ['/usr/bin/dig', '+time=3', '+tries=1', '@1.1.1.1', 'example.com', 'A'],
              'dns_tcp': ['/usr/bin/dig', '+tcp', '+time=3', '+tries=1', '@1.1.1.1', 'example.com', 'A']}
    with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
        futures = {name: pool.submit(run, command) for name, command in checks.items()}
        report.update({name: future.result() for name, future in futures.items()})
        targets = [('web', 'https://example.com/', False),
                   ('codex_https', 'https://chatgpt.com/backend-api/codex/responses', False),
                   ('codex_upgrade', 'https://chatgpt.com/backend-api/codex/responses', True)]
        targets.append(('google_https', 'https://www.google.com/generate_204', False, ['--ipv4']))
        for candidate in report['google_dns_aaaa'].get('stdout', '').splitlines():
            try:
                address = str(ipaddress.IPv6Address(candidate.strip()))
            except ValueError:
                continue
            targets.append(('google_ipv6_https', 'https://www.google.com/generate_204', False,
                            ['--ipv6', '--resolve', 'www.google.com:443:[' + address + ']']))
            break
        report['transport'] = dict(pool.map(probe, targets))
        report['direct_tcp'] = dict(pool.map(direct_transport, [
            ('ipv4', socket.AF_INET, '1.1.1.1'),
            ('ipv6', socket.AF_INET6, '2606:4700:4700::1111')]))
    report['network_processes'] = matching_processes(['Hy2UI', 'hy2-tun-worker', 'hy2-local-tun-helper', 'Surge', 'hysteria'])
    directory = pathlib.Path(__file__).resolve().parent.parent / '.build/network-diagnostics'
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / (timestamp + '.json')
    descriptor = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'w') as stream:
        json.dump(report, stream, ensure_ascii=False, indent=2)
    print('Report:', path)
    for name, result in report['transport'].items():
        print(name, result)


if __name__ == '__main__':
    main()
