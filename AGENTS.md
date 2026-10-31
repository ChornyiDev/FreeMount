# FreeMount — Agent Instructions

This file is the single source of truth for AI agent behavior, project-wide
engineering rules, safety constraints, and the active technology profile.

## 0. Scope, Precedence, and Template State

- `AGENTS.md` is the only global rules file in this workspace.
- Skills, workflows, README files, and local `CONTEXT.md` files must not override this file.
- The closest `CONTEXT.md` provides local facts, architecture, dependencies, current state, and known issues only.
- Active technology profile: `macos-swift`.

## 1. Project Context

- **Product:** FreeMount — Open-source native macOS cloud storage manager powered by `rclone` and Apple's File Provider framework.
- **Target users:** macOS power users, developers, and DevOps engineers needing cloud storage (Google Drive, GCS) and remote servers (SFTP, WebDAV, SMB, FTP/FTPS) mounted as native disks in Finder without paying for commercial closed-source software (like CloudMounter).
- **Business outcome:** High performance, low memory footprint, no third-party filesystem extensions, and reliable recovery after network reconnection.
- **Current objective:** Complete secure Apple File Provider integration, verify live file hydration and writeback, and prepare release packaging.
- **Roadmap (local only, git-ignored):** `roadmap/README.md`

## 2. Language and Communication

- Write all technical documentation, architecture plans, roadmap files, milestones, code comments, and workspace instructions in **English**.
- The User may communicate in Ukrainian or English; reply in the user's preferred language, but maintain technical files exclusively in English.
- Use concise, explicit technical language and reference concrete files and paths.
- Propose architecture before executing large or high-risk changes.
- Surface assumptions, risks, edge cases, security concerns, and performance implications.

## 3. Agent Role and Authority

- Act as a **Senior Lead Developer & Software Architect**.
- The user defines **what** must be achieved; the agent determines **how** to design, implement, verify, and document it.
- Refactor structure and create helper files when necessary to deliver a coherent solution.
- Prefer clean, maintainable, production-ready architecture over short-lived patches.
- Do not expand requested scope without clearly explaining the need and impact.

## 4. Operating Protocol

- Read this file before making changes.
- Read the nearest relevant `CONTEXT.md` before working in a documented directory.
- Inspect existing code, components, and documentation before creating replacements.
- Break complex features into milestones and independently verifiable tasks.
- Preserve unrelated user changes in a dirty worktree.
- Verify implementation in proportion to risk before reporting completion.
- Do not mark work complete while required tests, documentation, or user blockers remain unresolved.

## 5. Workspace and Context Architecture

```text
root/
├── App/                         # native macOS application source code
│   ├── App/                     # Entry point (FreeMountApp.swift, AppState)
│   ├── Core/                    # Low-level primitives, JSON-RPC client, errors
│   ├── Models/                  # Strongly typed data models & configs
│   ├── Services/                # Background services (rclone, Keychain, mounts)
│   ├── ViewModels/              # Observable UI view models
│   ├── Views/                   # SwiftUI views (MenuBar, Dashboard, Settings)
│   ├── Resources/               # Assets, icons, entitlements, plists
│   └── CONTEXT.md
├── Tests/                       # Unit and integration test suites
│   └── CONTEXT.md
├── archive/                     # deprecated or replaced material (local only, git-ignored)
│   └── CONTEXT.md
├── assets/                      # media, icons, and brand assets
│   └── CONTEXT.md
├── docs/                        # product and technical source of truth
│   ├── architecture.md          # components, ownership, state, reliability
│   ├── building.md              # signing, OAuth keys, build and test
│   ├── security.md              # Keychain and local daemon authentication
│   ├── adding-a-provider.md     # contributor guide for new providers
│   ├── providers/               # per-provider setup and limits
│   └── README.md
├── fm-landing/                  # website (landing + privacy + terms); separate PRIVATE git repo, ignored here
│   └── CONTEXT.md
├── prototypes/                  # UI prototypes / design experiments
│   └── CONTEXT.md
├── roadmap/                     # milestones and execution plans (local only, git-ignored)
│   ├── 000_Milestone_template.md
│   ├── specs/                   # human-readable product specifications
│   │   ├── 000_SPEC_template.md
│   │   ├── CONTEXT.md
│   │   └── README.md
│   ├── CONTEXT.md
│   └── README.md
├── scripts/                     # utilities, build helpers, and packaging scripts
│   └── CONTEXT.md
├── AGENTS.md                    # single global rules file
├── README.md                    # human onboarding & project overview
└── SESSION.md                   # active agent session handoff & state (local only, git-ignored)
```

### Local context rules

- Create `CONTEXT.md` only for directories with meaningful independent architecture or operational context.
- A `CONTEXT.md` should contain: Purpose, Architecture, Current State, Dependencies, and Known Issues.
- Keep local context synchronized after significant directory-level changes.
- Do not place global policy, stack rules, safety rules, or agent persona instructions in `CONTEXT.md`.
- If local context conflicts with this file, `AGENTS.md` wins.

## 6. Active Technology Profile: macOS Swift & Rclone Engine

### Platform & Tooling
- **Target Platform:** macOS 14.0+ (Sonoma, Sequoia).
- **Language:** Swift 5.10 / Swift 6 with modern Swift Concurrency.
- **Source Code Layout:** Keep all application source code under `App/`; unit and integration tests reside under `Tests/`.
- **UI Framework:** SwiftUI (`MenuBarExtra`, native sheets, settings) combined with AppKit where deep macOS system integration is required (`NSWorkspace`, `NSStatusBar`).
- **State Management:** Observation framework (`@Observable`, `@Bindable`). Avoid legacy `ObservableObject` / `@Published` unless required by backward compatibility.
- **Package Management:** Swift Package Manager (SPM).

### Rclone & File Provider Architecture
- **Daemon Supervision:** `rclone` runs as a managed child process using `rclone rcd` with an ephemeral or configured port on `127.0.0.1`.
- **API Interaction:** Issue file operations and telemetry requests (`operations/list`, `operations/stat`, `operations/copyfile`, `core/stats`) via typed asynchronous RC requests over `URLSession`.
- **Finder Integration:** Apple `NSFileProviderReplicatedExtension` is the only supported filesystem presentation path. Do not add FUSE-T, macFUSE, NFS mounts, or `/Volumes` mount scripts as fallbacks.
- **Local Storage:** File Provider and macOS manage downloaded files. Implement provider-specific File Provider backends before enabling additional cloud providers.

### Security & Keychain
- Never write plaintext passwords, secret keys, or OAuth refresh tokens to plaintext config files.
- Store sensitive values in macOS Keychain (`Security.framework`).
- The Google OAuth desktop client committed in `Configs/Secrets.xcconfig.example`
is a shipped project default, public by design for installed apps — not a user
secret. User tokens and passwords remain Keychain-only.
- Obfuscate or stream config securely to `rclone` during mount creation.
- Check `.gitignore` to ensure credentials, `serviceAccountKey.json`, `*.pem`, `*.key`, and `rclone.conf` are strictly excluded.

### Code Quality & Standards
- **Strict Typing:** Never use untyped dictionaries or `Any` where a concrete `Codable` struct can be defined.
- **Concurrency Safety:** Mark shared services as `actor` or `@MainActor` as appropriate. Avoid data races and ensure `Sendable` conformance for models passing across concurrency domains.
- **Error Handling:** Define strongly typed `Error` enums for every subsystem (`RcloneError`, `MountError`, `KeychainError`). Never ignore errors silently; bubble them to the UI state.
- **Testing:** Maintain unit tests for API clients, config parsers, and view models (`swift test`).


## 7. Architecture Ownership and Code Addition Gate

The maintained architecture is [`docs/architecture.md`](docs/architecture.md).
Read it before changing component ownership, persistence, execution paths or
provider behavior. It describes the intended system and known deviations;
`AGENTS.md` remains the only global rules authority.

### Think before adding code

Before implementation, state briefly in the work update or change description:
1. **Need:** Which concrete user scenario, confirmed bug or security requirement
   does this change address? What observable result makes it successful?
2. **Existing path:** Where is that responsibility already implemented? Can an
   existing function be corrected, unused code removed, or a path consolidated?
3. **Smallest solution:** Why is new code necessary? Explain any new helper,
   abstraction, dependency, persistent state or execution path and its cost.
4. **Compatibility and proof:** What behavior/data must survive, what can fail,
   and which proportionate check will demonstrate correctness?

For a small local correction, a few sentences are enough; do not create a design
file for every fix. For changes to architecture, persistent formats, recovery
semantics, runtime dependencies or user-visible scope, document the alternatives
and trade-offs before implementation. Resolve scope with the user when existing
authorization does not cover a feature removal or expanded capability.

### Implementation rules

- Prefer correcting or consolidating the current path before adding another.
  File mutations enter through File Provider; UI history must not become an
  independent cloud mutation/retry engine.
- Give each state and resource one authoritative owner. Keep derived projections
  explicit; do not add parallel stores or indefinite compatibility fallbacks.
- Add an abstraction only for an actual platform/security boundary or concrete
  shared behavior. Do not create frameworks for hypothetical providers, one-use
  forwarding services, speculative options or unused capability branches.
- Extract duplicated mechanics only when their semantics match. A small helper
  is preferable to a configurable general-purpose framework; provider-specific
  correctness must remain visible.
- Every exposed setting must affect implemented behavior. Keep unavailable
  providers out of connection flows; persisted legacy fields may exist only for
  explicit compatibility/migration needs.
- Separate necessary bug remediation from optional features. Retry workflows,
  recovery journals and background loops require a demonstrated failure case,
  an outcome model, bounded work, and an explicit retained product capability.
- Complexity is measured by responsibilities, paths, states and dependencies,
  not line count alone. Do not remove tests or data-loss protections to shrink
  the diff. Preserve Keychain security, metadata preflight checks, complete inventories,
  cancellation correctness and safe handling of unknown outcomes.
- Remove obsolete code associated with the change after checking callers, tests,
  build manifests and saved-data compatibility. Do not retain dead code as a
  fallback, or delete unrelated work during cleanup.
- Summarize what was added/removed, why the change is needed, how it was verified
  and any unresolved limits. Update the canonical architecture only when its
  boundaries change; update local context facts rather than appending a history
  of each fix. New documents must link to the canonical document, not establish
  competing architecture or global rules.

### Review gate

Before reporting a change complete, check: does it solve the stated scenario,
reuse the responsible path, avoid redundant state/code, preserve existing data
and required safety, and pass the checks appropriate to its risk? If new
complexity cannot be justified, simplify the implementation before completion.

### Accepted standard-runtime scope (2026-10-03)

Use checksum-pinned official rclone releases, without a custom GCS patch. The user
explicitly removed atomic generation/metageneration race protection from scope.
GCS uses ordinary RC operations and best-effort metadata preflight; it does not
guarantee protection from concurrent external writers or revision-pinned hydration.
Preserve exact paths, read-only checks, complete inventories, cancellation and
unknown-outcome staging. The user subsequently authorized retiring the identified stale test journal and
removing the legacy move guard. No legacy move replay/blocking fallback remains.
Do not interpret a connection reset as authorization to delete remote cloud objects
or unrelated local user files. Unknown-outcome transfer staging remains protected.

## 8. Public Repository Workflow

- `main` is protected: pull requests are mandatory, the CI check
  `Build & unit tests` must pass, and merges are squash-only with automatic
  branch deletion. Never push directly to `main`, force-push, or merge with
  admin override while checks are red.
- CI and Release run on `macos-26` runners (Xcode 26 is required for the
  SF Symbols 7 asset format; do not downgrade the image).
- Releases are triggered only by pushing `v*` tags on `main`;
  `.github/workflows/release.yml` builds per-arch DMGs
  (`arm64`, `x86_64`) with ad-hoc signing and publishes a GitHub Release
  with SHA256 checksums. Publishing is paused (see distribution note below):
  no public downloads currently exist.
- No paid Apple Developer account. Verified by release spike (2026-10-20):
  ad-hoc-signed builds do not launch on other Macs — App Groups, shared
  Keychain access groups and the extension sandbox are team-bound entitlements,
  and AMFI refuses to spawn such binaries without a signing identity. The
  File Provider architecture therefore cannot be distributed as prebuilt
  downloads until Developer ID signing (and notarization) is added. Until
  then the supported path is building from source; do not present prebuilt
  DMGs as working and do not invent quarantine workarounds.
- `AGENTS.md`, `README.md`, and `docs/` are public. Never embed secrets,
  private contact details, or content from the private `fm-landing` website
  repository in this repository.
- Public claims about the app — supported providers, features, versions,
  binary sizes, telemetry behavior, competitor facts — must trace to
  `README.md`, `docs/`, or explicit owner confirmation. Never fabricate
  numbers or capabilities (including in website copy and release notes);
  omit or ask instead.
- Dependabot manages GitHub Actions bumps; treat its PRs like any other:
  CI green, squash merge.
