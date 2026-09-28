#!/usr/bin/env python3
"""Measure the production favicon cache with a synthetic, isolated disk corpus.

This is a cache microbenchmark, not whole-app memory or UI performance evidence.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import struct
import subprocess
import sys
import uuid
import zlib

ROOT = Path(__file__).resolve().parent.parent

STUBS = r'''
import AppKit
import SwiftUI
import WebKit
enum Store { static let folder = URL(fileURLWithPath: CommandLine.arguments[1]) }
@MainActor final class Tab {
    var web = WKWebView()
    var built: WKWebView? { web }
    var address: URL?
    var icon: NSImage?
    var shy = false
}
enum Web { static let userAgentName = "FaviconBenchmark" }
enum Palette { static let ink = Color.black; static let muted = Color.gray }
enum Motion { static var quick: Animation? { nil } }
'''

DRIVER = r'''
import AppKit
import Foundation
final class WeakImage {
    weak var image: NSImage?
    init(_ image: NSImage) { self.image = image }
}
@main struct Runner {
    @MainActor static func main() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .aqua)
        let cache = Favicons.shared
        var weakImages: [Int: WeakImage] = [:]
        func touch(_ key: Int) -> Bool {
            autoreleasepool {
                guard let image = cache.cached("host\(key).example") else { return false }
                // Force lazy source decoding on both versions before measuring residency.
                guard image.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil else { return false }
                weakImages[key] = WeakImage(image)
                return true
            }
        }
        func ready(_ host: String) async -> NSImage? {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if let image = cache.cached(host) { return image }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            return nil
        }
        func resolve(_ count: Int) async -> [String: Any] {
            let start = DispatchTime.now().uptimeNanoseconds
            var found = 0
            for key in 0..<count {
                if await ready("host\(key).example") != nil, touch(key) { found += 1 }
            }
            return ["resolved": found, "milliseconds": Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6]
        }
        func footprint() -> [String: Int] {
            var count = 0, bytes = 0
            for ref in weakImages.values {
                autoreleasepool {
                    if let image = ref.image,
                       let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                        count += 1
                        bytes += cg.bytesPerRow * cg.height
                    }
                }
            }
            return ["residentImages": count, "decodedBackingBytes": bytes]
        }
        func measure(_ operation: () -> Int) -> [String: Any] {
            let start = DispatchTime.now().uptimeNanoseconds
            let found = operation()
            return ["resolved": found, "milliseconds": Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6]
        }
        var report: [String: Any] = [:]
        report["coldLookup200"] = measure { (0..<200).filter { touch($0) }.count }
        report["coldCompletion200"] = await resolve(200)
        // Time public cache lookups without adding decode/instrumentation cost.
        report["hot2000"] = measure {
            var count = 0
            for _ in 0..<10 {
                for i in 0..<200 {
                    autoreleasepool { if cache.cached("host\(i).example") != nil { count += 1 } }
                }
            }
            return count
        }
        report["workingSet"] = footprint()
        report["fill600"] = await resolve(600)
        report["overflow"] = footprint()
        report["reload600"] = await resolve(600)
        report["afterReload"] = footprint()
        var large: [[String: Int]] = []
        for side in [512, 4096] {
            let resolved = await ready("large\(side).example")
            autoreleasepool {
                if let image = resolved,
                   let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    large.append(["sourceSide": side, "decodedWidth": cg.width, "decodedHeight": cg.height,
                                  "decodedBackingBytes": cg.bytesPerRow * cg.height])
                }
            }
        }
        report["largeSources"] = large
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    }
}
'''


def png(side, color):
    def chunk(kind, body):
        return struct.pack('>I', len(body)) + kind + body + struct.pack('>I', zlib.crc32(kind + body))
    rows = (b'\0' + bytes((*color, 255)) * side) * side
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', side, side, 8, 6, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=ROOT / 'Sources/Search/Icons.swift')
    parser.add_argument('--label', default='current')
    args = parser.parse_args()
    source = args.source.resolve()
    artifact = ROOT / '.local-performance' / (args.label + '-favicons-' + uuid.uuid4().hex[:10])
    folder = artifact / 'profile/icons'
    folder.mkdir(parents=True)
    for i in range(600):
        (folder / f'host{i}.example.png').write_bytes(png(64, (i * 37 % 256, i * 91 % 256, i * 173 % 256)))
    for side in (512, 4096):
        (folder / f'large{side}.example.png').write_bytes(png(side, (60, 120, 220)))
    (artifact / 'Stubs.swift').write_text(STUBS)
    (artifact / 'Driver.swift').write_text(DRIVER)
    compile_command = ['xcrun', 'swiftc', '-O', '-swift-version', '5', '-parse-as-library',
                       str(source), str(artifact / 'Stubs.swift'), str(artifact / 'Driver.swift'),
                       '-o', str(artifact / 'measure')]
    with (artifact / 'compile.log').open('w') as log:
        subprocess.run(compile_command, cwd=ROOT, check=True, stdout=log, stderr=subprocess.STDOUT)
    subprocess.run([str(artifact / 'measure'), str(folder.parent), str(artifact / 'measurements.json')], check=True)
    measurements = json.loads((artifact / 'measurements.json').read_text())
    report = dict(measurements=measurements, source=str(source), sourceSHA256=hashlib.sha256(source.read_bytes()).hexdigest(),
                  command=shlex.join([sys.executable, *sys.argv]), compileCommand=shlex.join(compile_command),
                  developerDir=os.environ.get('DEVELOPER_DIR'),
                  method='Synthetic 200-host hot set, 600-host overflow; weak references observe cache residency. '
                         'Backing bytes exclude metadata, compressed data, allocator overhead and tab-held images. '
                         'Both versions force CGImage decoding. This is not process RSS or a measured user session.')
    (artifact / 'result.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(measurements, indent=2))
    print('ARTIFACT', artifact / 'result.json')


if __name__ == '__main__':
    main()
