import Foundation
import CCBoxCore

do {
    let results = try await SandboxSelfTest.runAll()
    for result in results {
        print("[PASS] \(result.name) — \(result.detail)")
    }
    print("All \(results.count)/\(results.count) ccbox core & runtime checks passed.")
} catch {
    fputs("Verification failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
