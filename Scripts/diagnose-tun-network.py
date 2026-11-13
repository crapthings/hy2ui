#!/usr/bin/env python3
"""Read-only DNS/TCP/TLS diagnostics; never changes proxy, DNS, routes, or services."""
import argparse
import concurrent.futures
import datetime
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile


# Runs a bounded command without inherited proxy settings or raw environment output.
def execute(arguments, seconds=10):
    environment = {k: v for k, v in os.environ.items() if k.lower() not in ('http_proxy', 'https_proxy', 'all_proxy', 'no_proxy')}
    try:
        result = subprocess.run(arguments, capture_output=True, text=True, env=environment, timeout=seconds)
        return result.returncode, result.stdout, result.stderr
    except subprocess.TimeoutExpired:
        return 124, '', 'diagnostic command timed out'


# Queries HTTPS while recording only transport metadata, never response bodies or credentials.
def request(host, family=None, pinned=None, path='/'):
    command = ['/usr/bin/curl', '--disable', '--silent', '--show-error', '--proxy', '', '--noproxy', '*',
               '--connect-timeout', '4', '--max-time', '7', '--output', os.devnull, '--write-out', '%{json}']
    if family:
        command.append('-' + str(family))
    if pinned:
        command += ['--resolve', host + ':443:' + pinned]
    code, output, error = execute(command + ['https://' + host + path], 9)
    try:
        metrics = json.loads(output)
    except ValueError:
        metrics = {}
    return {'host': host, 'family': family or 'auto', 'pinned': pinned, 'curl_exit': code,
            'error': error[:400], **{k: metrics.get(k) for k in ('http_code', 'remote_ip', 'time_namelookup', 'time_connect', 'time_appconnect', 'time_starttransfer', 'time_total', 'ssl_verify_result')}}


# Reads the macOS system resolver's cached/selected addresses with a strict deadline.
def system_addresses(host):
    code, output, _ = execute(['/usr/bin/dscacheutil', '-q', 'host', '-a', 'name', host], 6)
    addresses = []
    for value in re.findall(r'^\s*(?:ip_address|ipv6_address):\s*(\S+)', output, re.M):
        try:
            addresses.append(str(ipaddress.ip_address(value)))
        except ValueError:
            pass
    return {'exit': code, 'addresses': addresses, 'surge_style_fake_ipv4': any(ipaddress.ip_address(x) in ipaddress.ip_network('198.18.0.0/15') for x in addresses if ':' not in x)}


# Obtains a comparison IPv4 address using a fixed DoH endpoint that bypasses system DNS.
def independent_address(host):
    url = 'https://cloudflare-dns.com/dns-query?name=' + host + '&type=A'
    code, output, _ = execute(['/usr/bin/curl', '--disable', '--silent', '--proxy', '', '--noproxy', '*',
                              '--resolve', 'cloudflare-dns.com:443:1.1.1.1', '--connect-timeout', '4', '--max-time', '7',
                              '--max-filesize', '65536', '-H', 'accept: application/dns-json', url], 9)
    if code:
        return None
    try:
        for answer in json.loads(output).get('Answer', []):
            if answer.get('type') == 1:
                address = ipaddress.IPv4Address(answer['data'])
                if address.is_global:
                    return str(address)
    except (ValueError, KeyError):
        pass
    return None


# Compares system-resolved and independently resolved HTTPS paths for one known endpoint.
def diagnose(host):
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        dns = pool.submit(system_addresses, host)
        doh = pool.submit(independent_address, host)
        ipv4 = pool.submit(request, host, 4)
        ipv6 = pool.submit(request, host, 6)
        address = doh.result()
        pinned = request(host, 4, address) if address else None
        return {'host': host, 'system_dns': dns.result(), 'independent_ipv4': address,
                'ipv4': ipv4.result(), 'ipv6': ipv6.result(), 'pinned_ipv4': pinned}


# Writes a private report suitable for collecting while the assistant's connection is unavailable.
def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--label', default='hy2ui', help='Name of the active capture mode')
    args = parser.parse_args()
    _, dns, _ = execute(['/usr/sbin/scutil', '--dns'])
    _, proxy, _ = execute(['/usr/sbin/scutil', '--proxy'])
    nameservers = re.findall(r'nameserver\[\d+\]\s*:\s*(\S+)', dns)
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        hosts = list(pool.map(diagnose, ['chatgpt.com', 'api.openai.com', 'pbs.twimg.com']))
    report = {'schema_version': 1, 'utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'label': args.label, 'system_nameservers': sorted(set(nameservers)),
              'system_http_proxy_enabled': bool(re.search(r'HTTPS?Enable\s*:\s*1', proxy)),
              'note': '401/403/404 still demonstrate an HTTP response, not successful authenticated API access. Independent DNS can select a different CDN edge. No credentials, prompts, or account data are sent.',
              'hosts': hosts}
    descriptor, filename = tempfile.mkstemp(prefix='hy2ui-network-', suffix='.json')
    with os.fdopen(descriptor, 'w') as handle:
        json.dump(report, handle, indent=2)
        handle.write('\n')
    print(filename)
    for host in hosts:
        print(host['host'], 'fake_dns=' + str(host['system_dns']['surge_style_fake_ipv4']),
              'IPv4=' + str(host['ipv4']['curl_exit']), 'IPv6=' + str(host['ipv6']['curl_exit']),
              'pinned=' + str(host['pinned_ipv4']['curl_exit'] if host['pinned_ipv4'] else 'unavailable'))


if __name__ == '__main__':
    main()
