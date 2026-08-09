# FUMINIWA Codex canonical deployment manifest v1

This document defines the bytes measured by `sidecar_bundle_sha256` in Codex
sidecar protocol v1. It is a supply-chain identity format, not a package
installer, a code-signing replacement, or an OS sandbox.

Checkpoint B3 implements two narrower identity primitives:

- a Node packager that copies a fixed 21-file, Darwin arm64, Codex 0.147.0
  allowlist into a newly created candidate root; and
- an internal Swift verifier compiled only into `FUMINIWAExperimental`, with
  canonical bytes matching the Node v1 oracle.

The resulting digest is a **build-time identity candidate**, not a production
approval or an execution capability. B4-A now provides the Experimental native
compile-time approval contract, but its nested production catalog is
intentionally empty and consumes no candidate. B4-B adds an Experimental-only,
non-executing exact Node inspector for the supplied path. It observes bounded
filesystem, byte, Mach-O, and Security identities, but returns no path, file
descriptor, process handle, or launch capability. B3/B4-B do not bundle or
approve Node, prove its version or actual-process identity, prove a complete
loaded-artifact inventory, bind verified bytes immutably to Node import or
path-based spawn, connect the SDK/CLI, or authorize protocol runtime mode
`codex_sdk`.

## Verification root and covered set

The caller supplies one absolute, normalized, canonical real path called the
deployment root. The root itself and every descendant are covered. The root
path is not encoded, so an otherwise identical tree has the same digest at a
different canonical installation location.

The deployment root is a dedicated candidate artifact assembled by
`packageCodexDeployment(source, destination)`. It is **not** the repository, an
`npm install` working tree, an ambient global package, or the user's normal
Codex home. The packager takes no caller-supplied file allowlist. The source root
and destination parent must use canonical absolute paths, the normalized new
destination must not overlap the source, and the destination must not already
exist. A noncanonical spelling such as a trailing slash is rejected before
output creation.

### Exact B3 arm64 candidate tree

The destination root mode is `0700`. The following 15 directories are derived
from the fixed file paths and created with mode `0755`:

```text
node_modules
src
node_modules/@openai
node_modules/@openai/codex
node_modules/@openai/codex-darwin-arm64
node_modules/@openai/codex-sdk
node_modules/@openai/codex-darwin-arm64/vendor
node_modules/@openai/codex-sdk/dist
node_modules/@openai/codex/bin
node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin
node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin
node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex-path
node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex-resources
node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex-resources/zsh
node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex-resources/zsh/bin
```

The fixed 21 files are:

| Root-relative path | Mode |
| --- | ---: |
| `package.json` | `0644` |
| `package-lock.json` | `0644` |
| `src/main.mjs` | `0644` |
| `src/protocol.mjs` | `0644` |
| `src/session.mjs` | `0644` |
| `node_modules/@openai/codex-sdk/LICENSE` | `0644` |
| `node_modules/@openai/codex-sdk/README.md` | `0644` |
| `node_modules/@openai/codex-sdk/dist/index.d.ts` | `0644` |
| `node_modules/@openai/codex-sdk/dist/index.js` | `0644` |
| `node_modules/@openai/codex-sdk/dist/index.js.map` | `0644` |
| `node_modules/@openai/codex-sdk/package.json` | `0644` |
| `node_modules/@openai/codex/README.md` | `0644` |
| `node_modules/@openai/codex/bin/codex.js` | `0755` |
| `node_modules/@openai/codex/package.json` | `0644` |
| `node_modules/@openai/codex-darwin-arm64/README.md` | `0644` |
| `node_modules/@openai/codex-darwin-arm64/package.json` | `0644` |
| `node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex-package.json` | `0644` |
| `node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex` | `0755` |
| `node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex-code-mode-host` | `0755` |
| `node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex-path/rg` | `0755` |
| `node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex-resources/zsh/bin/zsh` | `0755` |

This policy is arm64-only. It neither contains nor approves an x86_64 tree or
the Node executable. npm's `node_modules/.bin`, tests, packager/manifest source,
documentation, caches, request working directories, `CODEX_HOME`, credentials,
and build scratch data are omitted. After copying, the canonical manifest has no
include globs: the root, all 15 directories, and all 21 covered files must be the
exact destination shape. The optional self file below is inspected separately.

The sole exclusion is the optional regular file at the root-relative path:

```text
.fuminiwa-codex-deployment-manifest-v1.bin
```

That name is excluded only at the root. The same basename in a subdirectory is
covered. If the root-level name exists, it must be a non-hard-linked regular
file; a directory, symlink, or special file at that name is rejected. The file
may contain the canonical bytes for inspection, but a verifier never trusts it
as input: it regenerates the manifest from the tree and compares the resulting
root digest with an independently supplied expected value. B4-A provides the
closed compile-time policy type, but the empty production catalog contains no
approved value and never imports this self file.

## Fixed package identity and copy operation

Before destination creation, the B3 packager validates the root dependency,
lockfile v3 records, installed package metadata, and platform layout without
importing or launching the SDK, CLI, or provider package. These identities are
fixed in the packager policy:

| Package | Exact version | Exact lockfile SRI |
| --- | --- | --- |
| `@openai/codex-sdk` | `0.147.0` | `sha512-nJL0maDBZy31uEArs+u46tW22veNdHjfs96AGaFTnI3jF+g8U+a422uaPiDZwEKmyxcNwStTRz6sIh6C7XxGFQ==` |
| `@openai/codex` | `0.147.0` | `sha512-EQLEXecAG2ptxI7UpBMo2TR/ga5596/c/OsYF/0LoUDh5JANZ7IoGqlzBEWbuEVQ76JePIbtTW/ihCkp1a7Z3w==` |
| `@openai/codex-darwin-arm64` | `0.147.0-darwin-arm64` | `sha512-BEUVkiOW7kLcRyrMLfAr/h9wF8sRVJyZDy6OHtVn6QGDXiv3BvAZVTY1Pu9xF7KdIdkYXbp4uayN0aDQQaAUJw==` |

The installed SDK must depend on CLI `0.147.0`; the CLI must name the arm64
optional package exactly; the platform metadata must declare only Darwin arm64;
and `codex-package.json` must declare layout version 1, target
`aarch64-apple-darwin`, the fixed entrypoint, resource directory, and path
directory. The three selected package subtrees reject missing or extra visible
and hidden descendants. Scoped hidden development entries are inspected, but
`node_modules/.bin` and `.package-lock.json` are not copied. A source-inspection
test also rejects static or dynamic provider imports, `require`/`createRequire`,
and `child_process` imports in the packager module itself.

Each allowlisted source file is opened with `O_NOFOLLOW`, fingerprinted before
and after reading, and SHA-256 hashed while its bytes are copied. Each
destination file is newly created with `O_EXCL | O_NOFOLLOW`, fixed to its
policy mode, synchronized, and required to be a one-link regular file with the
same size. The manifest regenerated from the exact destination must match the
source-copy size and digest for every file. The packager then writes the
non-authoritative self manifest and verifies that excluding it regenerates the
same canonical bytes.

Successful packaging returns exactly `packagerVersion`, `manifestVersion`,
`candidateRootDigest`, `recordCount`, and `canonicalManifestByteCount`. It does
not return an executable path or authority to run the candidate.

If failure occurs after destination creation, the packager deliberately does
not recursively remove anything. It throws `partial_destination_retained`, sets
`partialDestinationRetained` to true, preserves the underlying typed code, and
leaves the root unusable. The retained root must not be retried, completed in
place, verified as an approved artifact, or passed to a launcher. A subsequent
packaging attempt must use a different destination path that does not exist
before the new attempt. The caller or operator must first re-identify the
retained target and then manually quarantine or delete it. A destination that
existed before the call is rejected without modification or deletion.

## Entry policy

- The root and descendant directories are records.
- Regular files are records and must have link count exactly one. A hard link
  is rejected even if its other name is outside the root.
- Symbolic links are always rejected, including root aliases and links whose
  target remains inside the root.
- Sockets, FIFOs, devices, and every other special type are rejected.
- The caller must spell the root as its canonical `realpath`; a symlink in any
  root path component is rejected.

Only POSIX owner/group/other `rwx` bits are encoded. Set-user-ID, set-group-ID,
and sticky bits are rejected. Group- or world-writable entries are rejected.
The exact remaining nine permission bits of the root, each directory, and each
file affect the digest; the executable bit therefore cannot drift silently.
Owner/group IDs, timestamps, ACLs, extended attributes, file flags, sparse
layout, and code-signing metadata are not encoded. Packaging and signing Gates
must validate those independently where relevant.

## Paths and ordering

Directory names are read as filesystem bytes and decoded with fatal UTF-8.
Invalid UTF-8 and non-round-tripping names are rejected rather than replacement
decoded. No Unicode normalization or case folding is performed. A component
cannot be empty, `.` or `..`, contain NUL or `/`, or exceed 255 bytes. A
root-relative path cannot exceed 4,096 bytes.

Relative paths join components with the single byte `/` (`0x2F`). The root
directory has the unique empty relative path. Records are sorted by unsigned
lexicographic comparison of these UTF-8 path bytes. Locale, filesystem
enumeration order, and creation order have no effect.

## Fixed resource limits

Manifest v1 rejects a tree before accepting a digest if it exceeds any of:

| Resource | Limit |
| --- | ---: |
| Covered records, including the root | 100,000 |
| One path component | 255 bytes |
| One root-relative path | 4,096 bytes |
| One covered regular file | 536,870,912 bytes |
| Sum of covered regular-file logical sizes | 2,147,483,648 bytes |
| Optional self-excluded manifest file | 67,108,864 bytes |
| Canonical manifest byte stream | 67,108,864 bytes |

File size is logical byte length, not allocated blocks. A sparse file over the
applicable limit is rejected before its content is read. Although the optional
self file does not affect the digest, its type, link count, safe mode, size, and
stability during verification are still checked.

## Canonical binary format

All integers are unsigned big-endian. No padding, alignment, newline, JSON, or
terminal byte is present beyond the fields below.

```text
manifest = magic[35]
           version:u32
           record_count:u64
           record...

magic = ASCII "FUMINIWA-CODEX-DEPLOYMENT-MANIFEST" + NUL

record = payload_length:u64
         payload[payload_length]

directory payload = kind:u8                 # 0x01
                    path_length:u32
                    path_utf8[path_length]
                    permission_mode:u16

file payload = kind:u8                      # 0x02
               path_length:u32
               path_utf8[path_length]
               permission_mode:u16
               file_size:u64
               file_sha256[32]
```

`version` is `1`. `permission_mode` is the numeric value of the nine POSIX
permission bits (`0 ... 0o777`), not an ASCII octal string. `file_sha256` is the
raw 32-byte SHA-256 digest. Each file's `file_size` and digest cover exactly the
bytes read from offset zero through its recorded logical length.

The root digest is SHA-256 over the complete canonical manifest byte stream.
Its protocol representation is 64 lowercase hexadecimal characters. This root
digest is the value named `sidecar_bundle_sha256`; it is not a digest of the
self-excluded file and not merely a digest of `package-lock.json`.

## Construction and verification

The Node `createDeploymentManifest(root)` performs a bounded recursive
traversal. The Experimental Swift
`CodexDeploymentManifestVerifier.create(rootPath:)` implements the same format
with an explicit stack, so deep trees do not consume the Swift call stack. For a
regular file each implementation checks `lstat`, opens with `O_NOFOLLOW`,
compares `fstat`, hashes through the open descriptor, compares `fstat` again,
and finally confirms that the path still identifies the same device/inode,
type, mode, link count, size, mtime, and ctime. Swift opens directories with
`O_NOFOLLOW`; Node performs `lstat` around pathname enumeration. Both retain
directory fingerprints and check them again after traversal. A detected
content, inode, or directory mutation fails with `tree_changed`.

Node `verifyDeploymentManifest(root, expectedRootDigest)` and Swift
`CodexDeploymentManifestVerifier.verify(rootPath:expectedRootDigest:)`
regenerate the canonical bytes and compare the result with an independently
supplied 64-character lowercase SHA-256 value using a full-byte accumulated
comparison. They do not read the expected digest from the self file or fall
back to another root or runtime. The Swift API is internal and Experimental;
it does not hard-code the 21 paths and is not wired to an approved catalog entry
or the supervisor. The B4-A production catalog is deliberately empty.

The cross-language five-record oracle has 278 canonical bytes and digest:

```text
15b98ccfac850c24e2427249c55c9fba5aba29b6ef1632301136688c13d35288
```

Node and Swift agree on its exact bytes, unsigned UTF-8 record order, kinds,
modes, file sizes, and SHA-256 values. This synthetic oracle digest is not the
digest of the 21-file B3 candidate and is not a production allowlist value.

`verifyDeclaredLoadedFiles(root, expectedRootDigest, paths)` additionally
requires each caller-declared loaded file to use a canonical absolute path,
resolve below the verified root, and have a regular-file record. This helper
checks only the supplied inventory. It cannot prove that the inventory is
complete or that previously evaluated module bytes equal the file now on disk.

## B4-A approval contract and inventory roles

B4-A adds Experimental-only native types with an intentionally asymmetric trust
boundary:

- `CodexRuntimeApprovalPolicy` validates the closed compile-time policy shape;
- `CodexRuntimeApprovalProposal` is review material and is never authority; and
- `CodexApprovedRuntimeIdentity` has a private initializer owned by its nested
  `ProductionCatalog`.

`ProductionCatalog` is intentionally empty. There are zero approved candidate
roots, Node runtimes, SDK/CLI combinations, successful lookups, or launch
capabilities. A candidate digest, this self file, a verifier result, a proposal,
a `ready` frame, or an exactly observed local version/path/SHA-256/CDHash/signing
identity cannot populate the catalog. Promotion requires an independent,
reviewed native-source change; generation and observation cannot approve their
own output.

A **deployment candidate** is the complete B3 copied and canonically measured
set. It is not itself an approval inventory and does not imply that every file is
evaluated. Approval records use these distinct roles:

- `evaluatedSource`: JavaScript or equivalent source that may actually be
  evaluated;
- `resolutionMetadata`: package/module metadata that affects resolution;
- `executable`: Node, CLI, broker, or helper executable code;
- `conditional`: lazy/dynamic modules, native addons, libraries, or runtime data
  that may be reached only on some paths;
- `provenance`: lockfiles, licenses, and other origin evidence that is not
  runtime source;
- `requestData`: prompt, schema, selected manuscript, response, credential, and
  request identifiers, which are never artifact identity;
- `operatingSystemTrust`: an explicit Apple sealed-OS trust boundary, not an
  implicit wildcard; and
- `forbidden`: any artifact whose read, evaluation, or execution must fail.

Content identity is separately classified as `exactFile`, `boundedRequestData`,
`operatingSystemProvided`, or `forbidden`. Exact artifacts require their fixed
identity; bounded request data requires a later dedicated
location/type/resource policy;
OS-provided content requires an explicit host trust policy; forbidden content
must not be read, evaluated, or executed. Invalid role/content-identity
combinations fail policy validation. Request data never enters the deployment
digest, and OS trust never becomes an unbounded ambient allowlist.

Policy generation is not persistent monotonic state. B4-A makes no claim that an
older signed app, older catalog, or previously approved runtime cannot be used
after downgrade. Revocation and anti-rollback require a separate signed update
floor and tamper-resistant persistent-state decision.

## B4-B exact Node executable observation

B4-B adds `CodexNodeExecutableInspector` only to `FUMINIWAExperimental`. Its
input is one caller-supplied absolute path and one requested architecture. Its
output is a non-authority observation containing the requested architecture,
Mach-O container and contained architectures, byte count, SHA-256, owner user
ID, permission mode, and code-signature observation. It intentionally returns
no path, file descriptor, process handle, approved identity, or launch
capability, and it does not mutate B4-A's empty production catalog.

The input path must be NFC raw UTF-8, absolute, at most `PATH_MAX - 1` bytes,
and contain no NUL, backslash, control, illegal, format, U+2028, or U+2029
character. The raw bytes must equal `realpath`, and an
`O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK` descriptor's `F_GETPATH`.
The object must be a non-hard-linked regular file owned by the effective user,
with an owner execute bit and without set-id, sticky, group-write, or
world-write bits.

The inspector hashes the complete descriptor with bounded `pread` calls and
rejects empty files or files over 512 MiB. It strictly parses 64-bit thin,
fat32, and fat64 Mach-O containers, including byte order, CPU type/subtype,
slice bounds, alignment, overlap, duplicate architectures, executable file
type, reserved fields, and bounded load-command sizes. Only arm64 and x86_64
are recognized, and the requested architecture must be present. The limits are
64 slices and 4,096 load commands per parsed slice.

Security observation uses `SecStaticCodeCreateWithPathAndAttributes` with
`kSecCodeAttributeArchitecture` set to the requested `arm64` or `x86_64`
slice. Validity is checked with strict, all-architectures, single-threaded, and
no-network flags; signing information supplies the requested slice's 20-byte
CDHash when available. A universal Mach-O and its architecture-selected CDHash
remain observations only. `valid`, `unsigned`, `invalid`, and `unavailable`
results are recorded rather than promoted; in particular, returning an invalid
or unsigned observation is not approval to execute it.

Before returning, the inspector repeats descriptor/path identity checks around
hash/Mach-O reading and Security observation. Device, inode, mode, link count,
owner/group, size, mtime, ctime, birthtime, flags, generation, canonical path,
and `F_GETPATH` must remain stable. These checks detect the exercised mutation
races, but they do not prevent a same-user process from swapping the path or
bytes after the observation returns. B4-B does not inspect Node's version,
spawn Node, inspect an actual process, retain the verified descriptor for use,
or bind later imports and executable loads to these bytes.

## TOCTOU and loaded-module containment boundary

The filesystem checks narrow accidental build and verification races; they do
not make a mutable same-user directory an adversarially safe trust root. Child
paths are still resolved through pathname APIs rather than a root-anchored
`openat` walk. A same-user process can race source or destination ancestors,
temporarily substitute and restore a root or child, or mutate the candidate
after verification. The Node module containing its verifier is also not an
independent trust anchor if it was itself loaded from the unverified tree.

Before runtime mode `codex_sdk` can be enabled, B4 and later isolation Gates
must establish all of the following:

1. B4-A's empty production catalog is populated only by an independently
   reviewed native-source change. The candidate, proposal, observed runtime, and
   generated self file are never authority.
2. B4-B non-executingly observes the supplied canonical path, bounded bytes,
   ownership/mode/link count, strict thin/fat Mach-O architecture, and
   architecture-selected Security validity/CDHash. It does not inspect Node's
   version, spawn Node, promote the observation, or retain a use capability.
3. B4-C, the next checkpoint, starts a child suspended and validates the actual
   process identity before user code can run. Mismatch is killed and reaped
   before resume. A path hash or pre-spawn signature check alone is insufficient,
   and actual Node identity does not bind later JavaScript or CLI loads.
4. B4-D uses an interactive transport: spawn without request data, send only
   content-free `hello`, validate native identity and exact `ready`, and only then
   permit manuscript-bearing `start`. Concatenating `hello` and `start` into the
   existing one-shot supervisor input is forbidden.
5. B4-E closes the linker/loader, native broker/helper, and OS read/exec policy.
   No process can modify or substitute the verified root between verification
   and import/path-based spawn. The verified bytes must be bound immutably to
   the bytes actually evaluated or executed. The chosen mechanism must be
   demonstrated for the actual app bundle and
   development deployment; owner-writable mode alone does not close this gap.
6. A complete, enforced inventory covers every ESM/CJS module, resolution
   metadata, dynamic import, native addon, CLI executable, library, and runtime
   data file. Resolution outside the root, ambient/global fallback, and new
   imports after attestation are rejected.
7. The verification-to-import/spawn sequence, retained-partial handling, and
   complete
   loaded-file inventory are exercised under mutation and path-substitution
   tests before any manuscript-bearing `start` can be encoded or sent.

Until those properties and the remaining isolation/process Gates in
`docs/AI_INTEGRATION.md` are proven, manifest v1 is only a canonical identity
primitive and `codex_sdk` mode remains forbidden.

## Local test command

The manifest oracle, filesystem rejection, packager copy, B4-A policy, and B4-B
Node inspector suites use synthetic values, synthetic Mach-O bytes, or temporary
trees. One packager preflight reads the checked-in installed metadata and
lockfile without importing or launching the SDK/CLI. B4-A/B4-B spawn no process
and leave the standard target unchanged. The production catalog remains empty.
One content-free Security smoke test observes the OS-provided universal
`/usr/bin/git` without spawning it and checks separate arm64 and x86_64 CDHashes.
This OS executable and its architecture-selected values remain observations and
never approvals. No test in this Gate executes Node, SDK, CLI, or provider code,
or uses a credential, network, real manuscript, or `codex_sdk` runtime.

```sh
node --test test/deployment-manifest.test.mjs test/deployment-packager.test.mjs
# Swift verifier, approval, and Node inspector tests run as part of the
# FUMINIWAExperimental test target.
```
