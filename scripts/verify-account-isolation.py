#!/usr/bin/env python3
"""Run the account isolation XCTest cases against production objects with CLT only.

All credentials used by these cases are synthetic and live in temporary directories.
With Xcode installed, the same cases also run normally through `swift test`.
"""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
subprocess.run(["swift", "build"], cwd=root / "src", check=True)
build = (root / "src/.build/debug").resolve()
objects = [str(p) for target in ["CLIProxyMenuBar", "Yams", "CYaml"]
           for p in (build / (target + ".build")).rglob("*.o") if p.name != "main.swift.o"]
compiler = ["swiftc", "-parse-as-library", "-I", str(build / "Modules"),
            "-I", str(root / "src/.build/checkouts/Yams/Sources/CYaml/include"),
            "-F", str(build), "-framework", "Sparkle", "-Xlinker", "-rpath", "-Xlinker", str(build)]
test_classes = ["GlobalAccountIsolationTests", "MultiAccountIsolationTests", "ManualTokenImporterTests", "TokenRefreshServiceTests", "GrokUsageSyncTests", "ClaudeUsagePollerTests", "ClaudeProtocolTests"]
test_sources = [(name, (root / f"src/Tests/{name}.swift").read_text()) for name in test_classes]
methods = [(name, method, asynchronous, throwing) for name, source in test_sources
           for method, asynchronous, throwing in re.findall(r"func (test\w+)\(\)( async)?( throws)?\s*\{", source)]
shim = r'''
import Foundation
class XCTestCase {}
private var failures = 0
func XCTFail(_ message: String = "", file: StaticString = #file, line: UInt = #line) {
    failures += 1
    print("FAIL \(file):\(line): \(message)")
}
func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    if a != b { XCTFail(message.isEmpty ? "Values differ" : message, file: file, line: line) }
}
func XCTAssertEqual(_ a: Double, _ b: Double, accuracy: Double, file: StaticString = #file, line: UInt = #line) {
    if abs(a - b) > accuracy { XCTFail("Values differ", file: file, line: line) }
}
func XCTAssertFalse(_ value: Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    if value { XCTFail(message.isEmpty ? "Expected false" : message, file: file, line: line) }
}
func XCTAssertTrue(_ value: Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    if !value { XCTFail(message.isEmpty ? "Expected true" : message, file: file, line: line) }
}
func XCTAssertNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) {
    if value != nil { XCTFail("Expected nil", file: file, line: line) }
}
func XCTAssertNotNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) {
    if value == nil { XCTFail("Expected a value", file: file, line: line) }
}
func XCTUnwrap<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) throws -> T {
    guard let value else {
        XCTFail("Expected a value", file: file, line: line)
        throw NSError(domain: "AccountIsolation", code: 1)
    }
    return value
}
'''
calls = "\n".join(f'        {"try " if throwing else ""}{"await " if asynchronous else ""}{name}().{method}()\n        print("Checked {method}")'
                  for name, method, asynchronous, throwing in methods)
runner = '''
@main struct AccountIsolationChecks {
    static func main() async throws {
''' + calls + f'''
        if failures > 0 {{ exit(1) }}
        print("Passed {len(methods)} account isolation regression checks")
    }}
}}
'''
with tempfile.TemporaryDirectory(prefix="viberouter-account-verification-") as directory:
    source = Path(directory) / "AccountIsolationChecks.swift"
    binary = Path(directory) / "account-isolation"
    source.write_text(shim + runner)
    sources = [str(source)]
    for name, tests in test_sources:
        test_file = Path(directory) / f"{name}.swift"
        test_file.write_text(tests.replace("import XCTest\n", "import Foundation\n"))
        sources.append(str(test_file))
    subprocess.run([*compiler, *sources, *objects, "-o", str(binary)], check=True)
    subprocess.run([str(binary)], cwd=root, check=True)
    for name in ["ZAIAPIKeyStoreSpec", "CustomProviderCredentialStoreSpec"]:
        spec_source = Path(directory) / f"{name}.swift"
        spec_binary = Path(directory) / name
        spec_source.write_text("@testable import CLIProxyMenuBar\n" + (root / f"src/Verification/{name}.swift").read_text())
        subprocess.run([*compiler, str(spec_source), *objects, "-o", str(spec_binary)], check=True)
        subprocess.run([str(spec_binary)], cwd=root, check=True)
