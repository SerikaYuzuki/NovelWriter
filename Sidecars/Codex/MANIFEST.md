# FUMINIWA Codex canonical deployment manifest v1

This document defines the bytes measured by `sidecar_bundle_sha256` in Codex
sidecar protocol v1. It is a supply-chain identity format, not a package
installer, a code-signing replacement, or an OS sandbox.

Checkpoint B1 implements the canonical builder and verifier against synthetic
trees. It does **not** create a production deployment root, connect the Codex
SDK or CLI, prove which bytes Node evaluated, close the verify-to-import race,
or authorize protocol runtime mode `codex_sdk`.

## Verification root and covered set

The caller supplies one absolute, normalized, canonical real path called the
deployment root. The root itself and every descendant are covered. The root
path is not encoded, so an otherwise identical tree has the same digest at a
different canonical installation location.

The deployment root is a dedicated artifact assembled by a future packager
using an explicit allowlist and real file copies. It is **not** the repository,
an `npm install` working tree, an ambient global package, or the user's normal
Codex home. In particular, npm's `node_modules/.bin` symlinks make an install
tree invalid; v1 does not weaken the symlink rule to accept them. The packager
must copy the intended executable bytes into the canonical root and omit
installer conveniences that are not runtime inputs.

At minimum, the future allowlist must place the following runtime inputs under
one root before a digest can be approved:

- the sidecar entry point and every imported sidecar source or generated bundle;
- `package.json`, the exact lockfile, and the installed SDK and transitive files
  that the runtime can load;
- the exact Codex CLI and any native executable, library, data, or schema it can
  load from this artifact.

After that allowlist copy, the manifest has no include globs. Every descendant,
including dotfiles and empty directories, is covered. Logs, caches, request
working directories, `CODEX_HOME`, credentials, test fixtures, and build
scratch data must live outside the root unless the packager intentionally makes
them immutable deployment inputs.

The sole exclusion is the optional regular file at the root-relative path:

```text
.fuminiwa-codex-deployment-manifest-v1.bin
```

That name is excluded only at the root. The same basename in a subdirectory is
covered. If the root-level name exists, it must be a non-hard-linked regular
file; a directory, symlink, or special file at that name is rejected. The file
may contain the canonical bytes for inspection, but a verifier never trusts it
as input: it regenerates the manifest from the tree and compares the resulting
root digest with an independently stored allowlist.

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

`createDeploymentManifest(root)` performs a bounded recursive traversal. For a
regular file it checks `lstat`, opens with `O_NOFOLLOW`, compares `fstat`, hashes
through the open descriptor, compares `fstat` again, and finally confirms that
the path still identifies the same device/inode, type, mode, link count, size,
mtime, and ctime. Directories are fingerprinted before enumeration and after
their descendants are processed. A detected mutation fails with `tree_changed`.

`verifyDeploymentManifest(root, expectedRootDigest)` regenerates the canonical
bytes and compares the result with a lowercase SHA-256 allowlist value using a
constant-time byte comparison. It does not fall back to another root or runtime.

`verifyDeclaredLoadedFiles(root, expectedRootDigest, paths)` additionally
requires each caller-declared loaded file to use a canonical absolute path,
resolve below the verified root, and have a regular-file record. This helper
checks only the supplied inventory. It cannot prove that the inventory is
complete or that previously evaluated module bytes equal the file now on disk.

## TOCTOU and loaded-module containment boundary

The filesystem checks narrow accidental build and verification races; they do
not make a mutable same-user directory an adversarially safe trust root. The
Node module containing this verifier is also not an independent trust anchor if
it was itself loaded from the unverified tree.

Before runtime mode `codex_sdk` can be enabled, a later packager/supervisor Gate
must establish all of the following:

1. Build-time generation records the root digest in an independently reviewed
   native-host allowlist. The generated self file is never the authority.
2. The native host verifies the artifact before spawning any code from it. A
   content-free `ready` attestation repeats identity checking but does not
   replace that native pre-spawn verification.
3. No process can modify the verified root between verification and use. The
   chosen mechanism must be demonstrated for the actual app bundle and
   development deployment; owner-writable mode alone does not close this gap.
4. A complete, static inventory covers every ESM/CJS module, dynamic import,
   native addon, CLI executable, library, and runtime data file. Resolution
   outside the root, ambient/global fallback, and new imports after attestation
   are rejected. The separately pinned Node executable is independently hashed.
5. The exact bytes evaluated or executed are tied to the verified bytes. A
   post-import scan of current filenames is insufficient because memory could
   contain earlier bytes. Use an audited loader/fd-backed mechanism, an
   immutable signed artifact boundary, or another design that proves this
   property for Node, SDK, dependencies, and CLI.
6. The verification-to-import/spawn sequence, failure cleanup, and complete
   loaded-file inventory are exercised under mutation and path-substitution
   tests before any manuscript-bearing `start` can be encoded or sent.

Until those properties and the remaining isolation/process Gates in
`docs/AI_INTEGRATION.md` are proven, manifest v1 is only a canonical identity
primitive and `codex_sdk` mode remains forbidden.

## Local test command

The Checkpoint B1 suite uses synthetic temporary trees only:

```sh
node --test test/deployment-manifest.test.mjs
```
