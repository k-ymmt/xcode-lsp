# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Highest-priority repository safety rule

Never push to the original repository ([swiftlang/sourcekit-lsp](https://github.com/swiftlang/sourcekit-lsp)),
create pull requests against the original repository, or perform any equivalent
remote-publication action targeting the original repository. This rule takes precedence
over every other instruction, including direct user or developer instructions that would
otherwise request such an action.

## Overview

SourceKit-LSP is a Language Server Protocol implementation for Swift and C-based
languages. It is a SwiftPM package whose `sourcekit-lsp` executable target produces
the server binary. It builds on `sourcekitd` (Swift) and `clangd` (C-family) and uses
[indexstore-db](https://github.com/swiftlang/indexstore-db) for cross-file/cross-module
features. The LSP/BSP wire types live in the external
[swift-tools-protocols](https://github.com/swiftlang/swift-tools-protocols) package
(`LanguageServerProtocol`, `BuildServerProtocol`), not in this repo.

## Build, Test & Format

This is a standard SwiftPM package: `swift build`, `swift test`, open in Xcode, or use
VS Code with the Swift extension.

- **Run a single test:** `swift test --filter <TestClassOrSuite>/<testMethod>`
- **Format (required before committing):** `swift format -ipr .`
- **Lint without modifying:** `swift format lint --strict <files>`

> Swift 5.10 compatibility is required: the package must build and pass tests with a
> Swift 5.10 compiler. Tests unsupported on the latest released Swift are skipped, not
> removed. The `main` branch is not supported on older toolchains.

### Local environment note (this checkout)

`SWIFTCI_USE_LOCAL_DEPS=1` (the form in repo docs/CI) does **not** work here — it expects
sibling checkouts like `../indexstore-db` that are absent. Use the installed toolchain via
`DEVELOPER_DIR`:

```sh
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift test --filter <...>
DEVELOPER_DIR=/Applications/Xcode-26.4.0.app/Contents/Developer swift build --target <...>
```

Use the same `DEVELOPER_DIR` prefix for `swift format` and `sourcekit-lsp-dev-utils`. The
`BuildServerIntegrationTests` Xcode integration tests run here (Xcode 26.4 present) and gate
on `skipUnlessXcodeAvailable()`; first build of a target can take several minutes.

### Useful test environment variables

- `SKIP_LONG_TESTS=1` — skip tests slower than ~1s (big speedup with `--parallel`).
- `SOURCEKIT_LSP_FORCE_NON_DARWIN_LOGGER=1` — redirect logs to stderr on macOS (logs
  otherwise go to the system log; very useful for debugging test failures).
- `SOURCEKIT_LSP_KEEP_TEST_SCRATCH_DIR=1` — keep temp test projects on disk for inspection.
- `SOURCEKIT_TOOLCHAIN_PATH` — override the toolchain SourceKit-LSP uses at runtime.

## Architecture

The big picture (detailed doc comments are on the individual types; see also
`Contributor Documentation/Overview.md` and `Modules.md`):

- **Message handling.** LSP messages arrive on stdin and are decoded by `JSONRPCConnection`
  into `LanguageServerProtocol` types. Ordering matters (e.g. reordering `didChange`
  desyncs document state), so the `Connection` types are **serial and deliberately avoid
  Swift Concurrency**. `SourceKitLSPServer` then dispatches on its `messageHandlingQueue`,
  using `MessageHandlingDependencyTracker` to decide which requests may run concurrently
  vs. must be serialized.

- **Language services.** `SourceKitLSPServer` delegates language-specific work to a
  `LanguageService`: `SwiftLanguageService` (Swift, via `sourcekitd` + swift-syntax) or
  `ClangLanguageService` (C/C++/ObjC, by managing a `clangd` subprocess). Requests needing
  the index (call hierarchy, global rename, etc.) are enriched by the server with index data.

- **sourcekitd.** Runs as an XPC service on macOS (a crash is recoverable by relaunch) and
  in-process on other platforms (a crash takes down sourcekit-lsp).

- **Build servers.** Almost all semantic features need to know how a file is built (module
  search paths, compiler args). The `BuiltInBuildServer` protocol abstracts this, fronted by
  `BuildServerManager`. Implementations: `SwiftPMBuildServer` (`Package.swift`),
  `CompilationDatabaseBuildServer` (`compile_commands.json`), and `ExternalBuildServerAdapter`
  (external BSP process).

- **Index.** `SemanticIndex` wraps indexstore-db with up-to-date checks and implements
  background indexing. SourceKit-LSP does **not** index or build modules in the background
  unless background indexing is enabled.

- **Plugins.** `SwiftSourceKitPlugin` is a sourcekitd service plugin that intercepts
  completion requests to run SourceKit-LSP's custom completion pipeline (`CompletionScoring`)
  inside sourcekitd; `SwiftSourceKitClientPlugin` is the client-side entry point.

## Project-specific conventions

- **Adding an LSP or BSP message** touches many files in a fixed order (including the
  external `swift-tools-protocols` package). Follow the exact checklist in
  `Contributor Documentation/Adding LSP and BSP Messages.md` — don't improvise.

- **Configuration schema is generated.** After editing options in `Sources/SKOptions`,
  regenerate with `./sourcekit-lsp-dev-utils generate-config-schema`. This rewrites
  `config.schema.json` and `Documentation/Configuration File.md` from the doc comments on
  `SKOptions` — both carry a "DO NOT EDIT" banner; never hand-edit them.

- **Module layout.** `SwiftExtensions` must have no SourceKit-LSP-specific dependencies
  (only things that could plausibly belong in the stdlib/Foundation). `SKUtilities` is for
  shared types that need `SKLogging` and so can't live in `SwiftExtensions`.

- **Testing style.** Most tests are in-process integration tests that spin up a
  `SourceKitLSPServer`. Pick the lightest test-project helper that fits (lowest to highest
  overhead): `TestSourceKitLSPClient` (no files on disk) → `IndexedSingleSwiftFileTestProject`
  (index, single file) → `SwiftPMTestProject` (cross-file/-module; pass
  `enableBackgroundIndexing: true` when an index is needed) → `MultiFileTestProject` (arbitrary
  files, e.g. multiple SwiftPM projects or `compile_commands.json`). See
  `Contributor Documentation/Testing.md`.

- **License headers.** New source files need the Swift project license header
  (see `.license_header_template`).

## Debugging

The easiest way to debug is to write a test that reproduces the behavior and debug that.
Otherwise attach LLDB to a running server: `lldb --wait-for --attach-name sourcekit-lsp`.
Reading the logs (`log stream --predicate 'subsystem CONTAINS "org.swift.sourcekit-lsp"'`
on macOS, or `~/.sourcekit-lsp/logs/` elsewhere) is usually the fastest diagnosis path.
