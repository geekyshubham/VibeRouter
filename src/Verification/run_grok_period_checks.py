#!/usr/bin/env python3
"""Compile the production Grok protobuf parser and verify quota period semantics.

Run from any directory: python3 src/Verification/run_grok_period_checks.py
Uses only Python's standard library and swiftc; no XCTest runtime is required.
"""
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from run_grok_usage_sync_checks import BILLING_HEX

ROOT = Path(__file__).resolve().parents[2]


def varint(value):
    out = bytearray()
    while value > 127:
        out.append((value & 127) | 128)
        value >>= 7
    return bytes(out + bytes([value]))


def integer(field, value):
    return varint(field << 3) + varint(value)


def message(field, value):
    return varint((field << 3) | 2) + varint(len(value)) + value


def percent(field, value):
    return varint((field << 3) | 5) + struct.pack('<f', value)


def billing(kind, start, end, used=25, extra=b'', legacy=False):
    config = percent(1, used) if used is not None else b''
    if legacy:
        config += message(4, integer(1, start)) + message(5, integer(1, end))
    else:
        period = integer(1, kind) if kind is not None else b''
        period += message(2, integer(1, start)) + message(3, integer(1, end))
        config += message(8, period)
    return message(1, config + extra)


def swift_data(data):
    return 'Data([' + ','.join(map(str, data)) + '])'


def main():
    source = (ROOT / 'src/Sources/NativeUsageFetcher.swift').read_text()
    result = source[source.index('    struct GrokBillingParseResult {'):source.index('    private static func grokGRPCError(')]
    parser = source[source.index('    static func parseGrokBillingResponse('):]
    swift = 'import Foundation\nenum NativeUsageFetcher {}\nextension NativeUsageFetcher {\n' + result + parser
    now = 1_800_000_000
    end = now + 3600
    cases = [
        ('weekly stays weekly with one hour left', billing(2, end - 604800, end), 'Weekly', 10080, 25, end),
        ('monthly stays monthly with one hour left', billing(1, end - 2592000, end), 'Monthly', 43200, 25, end),
        ('five-hour uses the full period duration', billing(None, end - 18000, end), '5-hour', 300, 25, end),
        ('legacy weekly uses start and end', billing(None, end - 604800, end, legacy=True), 'Weekly', 10080, 25, end),
        ('omitted proto3 total means zero', billing(2, end - 604800, end, used=None), 'Weekly', 10080, 0, end),
        ('product usage does not replace omitted total', billing(2, end - 604800, end, used=None, extra=message(7, percent(1, 73))), 'Weekly', 10080, 0, end),
        ('currentPeriod end beats deprecated end', billing(2, end - 604800, end, extra=message(5, integer(1, end + 86400))), 'Weekly', 10080, 25, end),
        ('expired period retains its real reset', billing(2, now - 604860, now - 60), 'Weekly', 10080, 25, now - 60),
        ('captured weekly billing response', bytes.fromhex(BILLING_HEX)[5:99], 'Weekly', 10080, 73, 1_788_357_648),
    ]
    # Test the same parser with raw protobuf and grpc-web data/trailer frames.
    for name, body, label, minutes, used, reset in cases:
        for framed in (False, True):
            data = body
            if framed:
                trailer = b'grpc-status:0\r\n'
                data = b'\x00' + len(body).to_bytes(4, 'big') + body
                data += b'\x80' + len(trailer).to_bytes(4, 'big') + trailer
            swift += f'''\ndo {{
    let parsed = NativeUsageFetcher.parseGrokBillingResponse({swift_data(data)}, now: Date(timeIntervalSince1970: {now}))!
    precondition(parsed.label == "{label}", "{name}")
    precondition(parsed.windowMinutes == {minutes})
    precondition(parsed.usedPercent == {used})
    precondition(parsed.resetsAt?.timeIntervalSince1970 == {reset})
}}\n'''
    for body in (b'', message(1, message(7, percent(1, 73))), billing(2, end - 604800, end, used=float('nan'))):
        swift += f'\nprecondition(NativeUsageFetcher.parseGrokBillingResponse({swift_data(body)}, now: Date(timeIntervalSince1970: {now})) == nil)\n'
    swift += f'\nprint("All Grok period checks passed ({len(cases) * 2 + 3} parser cases)")\n'
    with tempfile.TemporaryDirectory(prefix='viberouter-grok-period-') as temp:
        path = Path(temp)
        (path / 'main.swift').write_text(swift)
        subprocess.run(['swiftc', str(path / 'main.swift'), '-o', str(path / 'checks')], check=True)
        subprocess.run([str(path / 'checks')], check=True)


if __name__ == '__main__':
    main()
