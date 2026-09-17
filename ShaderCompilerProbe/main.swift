import Darwin
import Foundation

let streamLength = 262_144
let sentinel = "largeDiagnosticSentinel"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}

if CommandLine.arguments.dropFirst().first == "--verify" {
    // Keep the verifier and its compiler child in one group so the test can
    // clean up both if compiler output handling ever blocks again.
    guard getpgrp() == getpid() || setpgid(0, 0) == 0 else {
        fail("Could not isolate the compiler probe process group")
    }
    guard setenv("SLANG_PATH", CommandLine.arguments[0], 1) == 0 else {
        fail("Could not configure the probe compiler")
    }
    do {
        _ = try SlangCompiler.compileToMetal(slangSource: "deliberately invalid shader")
        fail("Probe compiler unexpectedly succeeded")
    } catch SlangCompilerError.compilationFailed(let diagnostic) {
        guard diagnostic.contains(String(repeating: "o", count: streamLength)),
              diagnostic.contains(String(repeating: "e", count: streamLength)),
              diagnostic.contains(sentinel) else {
            fail("Compiler diagnostic lost or truncated an output stream")
        }
    } catch {
        fail("Unexpected compiler failure: \(error.localizedDescription)")
    }
} else if CommandLine.arguments.dropFirst().first == "--hang" {
    // Exercise forced termination, not only the happy path where SIGTERM works.
    signal(SIGTERM, SIG_IGN)
    while true { Thread.sleep(forTimeInterval: 1) }
} else {
    // The production compiler invokes this executable as its mock slangc.
    // Both streams exceed a pipe's capacity, exposing wait-before-drain bugs.
    FileHandle.standardOutput.write(Data(repeating: Character("o").asciiValue!, count: streamLength))
    FileHandle.standardError.write(Data(repeating: Character("e").asciiValue!, count: streamLength))
    FileHandle.standardError.write(Data("\n\(sentinel)\n".utf8))
    exit(1)
}
