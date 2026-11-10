#!/usr/bin/env python3
"""Record bounded, credential-free network evidence without modifying system configuration."""
import concurrent.futures
import datetime
import json
import os
import pathlib
import re
import subprocess
import urllib.parse


# Runs one read-only diagnostic with a bounded duration and output size.
def run(arguments, environment=None):
    try:
        result = subprocess.run(arguments, capture_output=True, text=True, timeout=15, env=environment)
        return {'exit': result.returncode, 'stdout': result.stdout[:24000], 'stderr': result.stderr[:2000]}
    except subprocess.TimeoutExpired:
        return {'error': 'diagnostic timed out'}


# Exposes only sanitized proxy destinations instead of process arguments or credentials.
def process_state():
    records = []
    listing = run(['/bin/ps', '-axo', 'pid,comm']).get('stdout', '')
    for line in listing.splitlines():
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
    name, url, upgrade = target
    environment = {key: value for key, value in os.environ.items() if key.lower() not in
                   ('http_proxy', 'https_proxy', 'all_proxy', 'no_proxy')}
    command = ['/usr/bin/curl', '--noproxy', '*', '--http1.1', '--connect-timeout', '5',
               '--max-time', '10', '--silent', '--show-error', '--output', '/dev/null',
               '--write-out', 'http=%{http_code} peer=%{remote_ip} tls=%{ssl_verify_result} connect=%{time_connect} total=%{time_total}']
    if upgrade:
        command += ['--header', 'Connection: Upgrade', '--header', 'Upgrade: websocket',
                    '--header', 'Sec-WebSocket-Version: 13',
                    '--header', 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==']
    command.append(url)
    return name, run(command, environment)


# Saves a portable report while preserving the network state that the user chose.
def main():
    timestamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    report = {'timestamp': timestamp,
              'scope': 'No credentials or authenticated API calls; HTTP 401/403 does not prove authenticated WebSocket success.',
              'codex': process_state()}
    checks = {'system_proxy': ['/usr/sbin/scutil', '--proxy'],
              'dns': ['/usr/sbin/scutil', '--dns'],
              'routes_ipv4': ['/usr/sbin/netstat', '-rn', '-f', 'inet'],
              'routes_ipv6': ['/usr/sbin/netstat', '-rn', '-f', 'inet6'],
              'chatgpt_dns': ['/usr/bin/dscacheutil', '-q', 'host', '-a', 'name', 'chatgpt.com']}
    with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
        futures = {name: pool.submit(run, command) for name, command in checks.items()}
        report.update({name: future.result() for name, future in futures.items()})
        targets = [('web', 'https://example.com/', False),
                   ('codex_https', 'https://chatgpt.com/backend-api/codex/responses', False),
                   ('codex_upgrade', 'https://chatgpt.com/backend-api/codex/responses', True)]
        report['transport'] = dict(pool.map(probe, targets))
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
