#!/usr/bin/env python3
"""Verify bounded native ownership snapshots and stale-owner rejection using child loopback sockets."""
import ctypes
import errno
import json
import pathlib
import socket
import subprocess
import sys
import time

# Defines an isolated socket owner that waits for its parent to finish inspecting metadata.
CHILD = '''import json, socket, sys
family = socket.AF_INET6 if sys.argv[1] == "6" else socket.AF_INET
udp = sys.argv[2] != "tcp"
s = socket.socket(family, socket.SOCK_DGRAM if udp else socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
s.bind(("::1" if family == socket.AF_INET6 else "127.0.0.1", int(sys.argv[5]) if len(sys.argv) > 5 else 0))
if sys.argv[2] != "unconnected": s.connect((sys.argv[3], int(sys.argv[4])))
print(json.dumps(s.getsockname()), flush=True)
sys.stdin.readline()
'''


# Mirrors the fixed-width adapter ABI rather than any private kernel socket structure.
class Owner(ctypes.Structure):
    _fields_ = [('start_seconds', ctypes.c_uint64), ('start_microseconds', ctypes.c_uint64),
                ('socket_identity', ctypes.c_uint64), ('pid', ctypes.c_int32), ('descriptor', ctypes.c_int32),
                ('source_port', ctypes.c_uint16), ('destination_port', ctypes.c_uint16),
                ('ipv6', ctypes.c_uint8), ('udp', ctypes.c_uint8), ('unconnected', ctypes.c_uint8), ('reserved', ctypes.c_uint8),
                ('source', ctypes.c_uint8 * 16), ('destination', ctypes.c_uint8 * 16)]


def main():
    """Check family separation, UDP ambiguity, process exits and reused identity without privileged routing."""
    root = pathlib.Path(__file__).resolve().parent.parent
    output = root / '.build/routing-tests'
    output.mkdir(parents=True, exist_ok=True)
    library = output / 'process_routing.dylib'
    subprocess.run(['xcrun', 'clang', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror', '-dynamiclib',
                    str(root / 'Native/bridge/process_routing.c'), '-framework', 'SystemConfiguration',
                    '-framework', 'CoreFoundation', '-o', str(library)], check=True)
    adapter = ctypes.CDLL(str(library), use_errno=True)
    emit = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.POINTER(Owner), ctypes.c_char_p, ctypes.c_void_p)
    adapter.hy2_collect_flow_owners.argtypes = [emit, ctypes.c_void_p]
    adapter.hy2_validate_flow_owner.argtypes = [ctypes.POINTER(Owner), ctypes.c_char_p]
    assert ctypes.sizeof(Owner) == 72
    assert adapter.hy2_process_lookup_available() == 1
    adapter.hy2_bind_direct_socket.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint]
    assert adapter.hy2_bind_direct_socket(-1, 1, 0) == -1
    assert ctypes.get_errno() == errno.ENETUNREACH
    times = []

    def snapshot():
        """Retain callback data only after the full bounded scan succeeds."""
        records = []
        def receive(owner, path, context):
            records.append((Owner.from_buffer_copy(owner.contents), bytes(path)))
            return 1
        callback = emit(receive)
        started = time.monotonic()
        assert adapter.hy2_collect_flow_owners(callback, None) == 1
        times.append(time.monotonic() - started)
        return records

    def candidates(records, ipv6, udp, host, source_port, dest_port):
        """Model exact-key lookup and unconnected-UDP fallback separately from record validation."""
        family = socket.AF_INET6 if ipv6 else socket.AF_INET
        address = socket.inet_pton(family, host).ljust(16, b'\0')
        exact, wildcard = [], []
        for owner, path in records:
            if owner.ipv6 != ipv6 or owner.udp != udp or owner.source_port != source_port:
                continue
            source_matches = bytes(owner.source) == address or (udp and bytes(owner.source) == b'\0' * 16)
            if not source_matches:
                continue
            if not owner.unconnected and bytes(owner.destination) == address and owner.destination_port == dest_port:
                exact.append((owner, path))
            elif owner.unconnected:
                wildcard.append((owner, path))
        return exact if exact else wildcard

    for version, family, host in [(4, socket.AF_INET, '127.0.0.1'), (6, socket.AF_INET6, '::1')]:
        for mode in ['tcp', 'udp', 'unconnected']:
            with socket.socket(family, socket.SOCK_STREAM if mode == 'tcp' else socket.SOCK_DGRAM) as destination:
                destination.bind((host, 0))
                if mode == 'tcp': destination.listen()
                port = destination.getsockname()[1]
                child = subprocess.Popen([sys.executable, '-c', CHILD, str(version), mode, host, str(port)],
                                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
                try:
                    source = json.loads(child.stdout.readline())
                    found = candidates(snapshot(), version == 6, mode != 'tcp', host, source[1], port)
                    assert len(found) == 1, (version, mode, len(found))
                    owner, path = found[0]
                    assert owner.pid == child.pid and adapter.hy2_validate_flow_owner(ctypes.byref(owner), path) == 1
                    reused = Owner.from_buffer_copy(owner); reused.start_seconds += 1
                    assert adapter.hy2_validate_flow_owner(ctypes.byref(reused), path) == 0
                    reused = Owner.from_buffer_copy(owner); reused.socket_identity ^= 1
                    assert adapter.hy2_validate_flow_owner(ctypes.byref(reused), path) == 0
                    assert adapter.hy2_validate_flow_owner(ctypes.byref(owner), b'/wrong/path') == 0
                finally:
                    child.stdin.close(); child.wait(timeout=5)
                assert adapter.hy2_validate_flow_owner(ctypes.byref(owner), path) == 0
    children = []
    try:
        for _ in range(2):
            bind_port = source[1] if children else 0
            child = subprocess.Popen([sys.executable, '-c', CHILD, '4', 'unconnected', '127.0.0.1', '9', str(bind_port)],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
            children.append(child); source = json.loads(child.stdout.readline())
        found = candidates(snapshot(), False, True, '127.0.0.1', source[1], 9)
        assert len(found) == 2 and all(owner.unconnected for owner, _ in found)
    finally:
        for child in children:
            child.stdin.close(); child.wait(timeout=5)
    print(f'IPv4/IPv6 TCP/UDP snapshots, shared UDP, process exit, PID/socket identity and path checks passed; max full scan {max(times)*1000:.1f} ms')


if __name__ == '__main__':
    main()
