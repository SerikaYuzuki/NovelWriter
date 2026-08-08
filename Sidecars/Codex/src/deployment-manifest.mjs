import { Buffer } from "node:buffer";
import { constants as fileConstants } from "node:fs";
import { lstat, open, opendir, realpath } from "node:fs/promises";
import { createHash, timingSafeEqual } from "node:crypto";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { TextDecoder } from "node:util";

export const DEPLOYMENT_MANIFEST_VERSION = 1;
export const DEPLOYMENT_MANIFEST_SELF_PATH =
  ".fuminiwa-codex-deployment-manifest-v1.bin";
export const MAXIMUM_DEPLOYMENT_ENTRY_COUNT = 100_000;
export const MAXIMUM_DEPLOYMENT_COMPONENT_BYTES = 255;
export const MAXIMUM_DEPLOYMENT_PATH_BYTES = 4_096;
export const MAXIMUM_DEPLOYMENT_FILE_BYTES = 512 * 1_024 * 1_024;
export const MAXIMUM_DEPLOYMENT_TOTAL_FILE_BYTES = 2 * 1_024 * 1_024 * 1_024;
export const MAXIMUM_CANONICAL_MANIFEST_BYTES = 64 * 1_024 * 1_024;

const MANIFEST_MAGIC = Buffer.from("FUMINIWA-CODEX-DEPLOYMENT-MANIFEST\0", "ascii");
const RECORD_KIND_DIRECTORY = 0x01;
const RECORD_KIND_FILE = 0x02;
const READ_CHUNK_BYTES = 64 * 1_024;
const utf8Decoder = new TextDecoder("utf-8", { fatal: true });
const sha256Pattern = /^[0-9a-f]{64}$/;

export class DeploymentManifestError extends Error {
  constructor(code, message) {
    super(message);
    this.name = "DeploymentManifestError";
    this.code = code;
  }
}

function fail(code, message) {
  throw new DeploymentManifestError(code, message);
}

function asPathString(root) {
  if (root instanceof URL) {
    if (root.protocol !== "file:") {
      fail("invalid_root", "deployment root URL must use the file protocol");
    }
    return fileURLToPath(root);
  }
  if (typeof root !== "string" || root.length === 0) {
    fail("invalid_root", "deployment root must be a nonempty absolute path");
  }
  return root;
}

async function requireCanonicalRoot(root) {
  const candidate = asPathString(root);
  if (!path.isAbsolute(candidate) || path.normalize(candidate) !== candidate) {
    fail("invalid_root", "deployment root must be an absolute normalized path");
  }

  let canonical;
  let stats;
  try {
    canonical = await realpath(candidate);
    stats = await lstat(candidate, { bigint: true });
  } catch {
    fail("invalid_root", "deployment root is unavailable");
  }

  if (canonical !== candidate || !stats.isDirectory() || stats.isSymbolicLink()) {
    fail("invalid_root", "deployment root must be a canonical non-symlink directory");
  }
  validateMode(stats, "deployment root");
  return { path: candidate, bytes: Buffer.from(candidate, "utf8"), stats };
}

function permissionMode(stats) {
  return Number(stats.mode & 0o777n);
}

function validateMode(stats, label) {
  if ((stats.mode & 0o7000n) !== 0n) {
    fail("invalid_mode", `${label} uses set-id or sticky mode bits`);
  }
  if ((stats.mode & 0o022n) !== 0n) {
    fail("invalid_mode", `${label} is group- or world-writable`);
  }
}

function statFingerprint(stats) {
  return [
    stats.dev,
    stats.ino,
    stats.mode,
    stats.nlink,
    stats.size,
    stats.mtimeNs,
    stats.ctimeNs,
  ];
}

function sameFingerprint(left, right) {
  const leftFingerprint = statFingerprint(left);
  const rightFingerprint = statFingerprint(right);
  return leftFingerprint.every((value, index) => value === rightFingerprint[index]);
}

function childAbsolutePath(parentBytes, componentBytes) {
  return Buffer.concat([parentBytes, Buffer.of(0x2f), componentBytes]);
}

function childRelativePath(parentBytes, componentBytes) {
  if (parentBytes.length === 0) {
    return Buffer.from(componentBytes);
  }
  return Buffer.concat([parentBytes, Buffer.of(0x2f), componentBytes]);
}

function decodePathComponent(componentBytes) {
  if (
    componentBytes.length === 0 ||
    componentBytes.length > MAXIMUM_DEPLOYMENT_COMPONENT_BYTES
  ) {
    fail("invalid_path", "deployment path component has an invalid byte length");
  }

  let component;
  try {
    component = utf8Decoder.decode(componentBytes);
  } catch {
    fail("invalid_path", "deployment path component is not valid UTF-8");
  }

  if (
    component === "." ||
    component === ".." ||
    component.includes("/") ||
    component.includes("\0") ||
    !Buffer.from(component, "utf8").equals(componentBytes)
  ) {
    fail("invalid_path", "deployment path component is not canonical UTF-8");
  }
  return component;
}

export function decodeCanonicalDeploymentRelativePath(relativeBytes) {
  if (!(relativeBytes instanceof Uint8Array)) {
    fail("invalid_path", "deployment relative path must be a byte sequence");
  }
  const bytes = Buffer.from(
    relativeBytes.buffer,
    relativeBytes.byteOffset,
    relativeBytes.byteLength,
  );
  if (bytes.length === 0) {
    fail("invalid_path", "deployment relative path must not be empty");
  }
  if (bytes.length > MAXIMUM_DEPLOYMENT_PATH_BYTES) {
    fail("resource_limit", "deployment relative path exceeds the byte limit");
  }

  const components = [];
  let componentStart = 0;
  for (let index = 0; index <= bytes.length; index += 1) {
    if (index === bytes.length || bytes[index] === 0x2f) {
      components.push(decodePathComponent(bytes.subarray(componentStart, index)));
      componentStart = index + 1;
    }
  }
  return components.join("/");
}

function assertSupportedEntry(stats, label) {
  if (stats.isSymbolicLink()) {
    fail("symlink", `${label} is a symbolic link`);
  }
  if (!stats.isDirectory() && !stats.isFile()) {
    fail("unsupported_entry", `${label} is not a regular file or directory`);
  }
  if (stats.isFile() && stats.nlink !== 1n) {
    fail("hardlink", `${label} is a hard-linked regular file`);
  }
  validateMode(stats, label);
}

function addEntry(context, entry) {
  context.entryCount += 1;
  if (context.entryCount > MAXIMUM_DEPLOYMENT_ENTRY_COUNT) {
    fail("resource_limit", "deployment entry count exceeds the limit");
  }
  const recordByteCount =
    8 + 1 + 4 + entry.pathBytes.length + 2 + (entry.kind === "file" ? 8 + 32 : 0);
  context.canonicalByteCount += recordByteCount;
  if (context.canonicalByteCount > MAXIMUM_CANONICAL_MANIFEST_BYTES) {
    fail("resource_limit", "canonical deployment manifest exceeds the byte limit");
  }
  context.entries.push(entry);
}

function requireStableEntry(initialStats, finalStats, label) {
  if (!sameFingerprint(initialStats, finalStats)) {
    fail("tree_changed", `${label} changed while the manifest was computed`);
  }
}

async function stableLstat(absoluteBytes, label) {
  try {
    return await lstat(absoluteBytes, { bigint: true });
  } catch {
    fail("tree_changed", `${label} became unavailable during manifest computation`);
  }
}

async function hashRegularFile(context, absoluteBytes, relativePath, initialStats) {
  if (initialStats.size > BigInt(MAXIMUM_DEPLOYMENT_FILE_BYTES)) {
    fail("resource_limit", `${relativePath} exceeds the per-file byte limit`);
  }
  context.totalFileBytes += initialStats.size;
  if (context.totalFileBytes > BigInt(MAXIMUM_DEPLOYMENT_TOTAL_FILE_BYTES)) {
    fail("resource_limit", "deployment files exceed the aggregate byte limit");
  }

  let handle;
  try {
    handle = await open(
      absoluteBytes,
      fileConstants.O_RDONLY | fileConstants.O_NOFOLLOW,
    );
  } catch {
    fail("tree_changed", `${relativePath} could not be opened without following links`);
  }

  try {
    const beforeRead = await handle.stat({ bigint: true });
    assertSupportedEntry(beforeRead, relativePath);
    if (!beforeRead.isFile() || !sameFingerprint(initialStats, beforeRead)) {
      fail("tree_changed", `${relativePath} changed before it was read`);
    }

    const digest = createHash("sha256");
    const buffer = Buffer.allocUnsafe(READ_CHUNK_BYTES);
    let position = 0;
    const expectedSize = Number(beforeRead.size);
    while (position < expectedSize) {
      const requested = Math.min(buffer.length, expectedSize - position);
      const { bytesRead } = await handle.read(buffer, 0, requested, position);
      if (bytesRead === 0) {
        fail("tree_changed", `${relativePath} became shorter while it was read`);
      }
      digest.update(buffer.subarray(0, bytesRead));
      position += bytesRead;
    }

    const afterRead = await handle.stat({ bigint: true });
    requireStableEntry(beforeRead, afterRead, relativePath);
    const afterPathRead = await stableLstat(absoluteBytes, relativePath);
    requireStableEntry(afterRead, afterPathRead, relativePath);

    return {
      size: expectedSize,
      sha256: digest.digest("hex"),
      stableStats: afterPathRead,
    };
  } finally {
    await handle.close().catch(() => {});
  }
}

function isSelfManifest(relativeBytes) {
  return relativeBytes.equals(Buffer.from(DEPLOYMENT_MANIFEST_SELF_PATH, "utf8"));
}

async function boundedDirectoryComponents(
  context,
  absoluteBytes,
  relativeBytes,
  relativePath,
) {
  let directory;
  try {
    directory = await opendir(absoluteBytes, { encoding: "buffer", bufferSize: 32 });
  } catch {
    fail("tree_changed", `${relativePath} could not be enumerated`);
  }

  const components = [];
  let prospectiveCoveredEntries = 0;
  try {
    for await (const dirent of directory) {
      const componentBytes = dirent.name;
      decodePathComponent(componentBytes);
      const childRelative = childRelativePath(relativeBytes, componentBytes);
      if (!isSelfManifest(childRelative)) {
        prospectiveCoveredEntries += 1;
        if (
          context.entryCount + prospectiveCoveredEntries >
          MAXIMUM_DEPLOYMENT_ENTRY_COUNT
        ) {
          fail("resource_limit", "deployment entry count exceeds the limit");
        }
      }
      components.push(Buffer.from(componentBytes));
    }
  } catch (error) {
    if (error instanceof DeploymentManifestError) {
      throw error;
    }
    fail("tree_changed", `${relativePath} changed while it was enumerated`);
  } finally {
    await directory.close().catch(() => {});
  }
  components.sort(Buffer.compare);
  return components;
}

async function visitDirectory(context, absoluteBytes, relativeBytes, initialStats) {
  const relativePath =
    relativeBytes.length === 0
      ? "<root>"
      : decodeCanonicalDeploymentRelativePath(relativeBytes);
  assertSupportedEntry(initialStats, relativePath);
  if (!initialStats.isDirectory()) {
    fail("unsupported_entry", `${relativePath} must be a directory`);
  }

  addEntry(context, {
    kind: "directory",
    path: relativeBytes.length === 0 ? "" : relativePath,
    pathBytes: Buffer.from(relativeBytes),
    mode: permissionMode(initialStats),
  });

  const components = await boundedDirectoryComponents(
    context,
    absoluteBytes,
    relativeBytes,
    relativePath,
  );

  for (const componentBytes of components) {
    decodePathComponent(componentBytes);
    const childAbsolute = childAbsolutePath(absoluteBytes, componentBytes);
    const childRelative = childRelativePath(relativeBytes, componentBytes);
    const childPath = decodeCanonicalDeploymentRelativePath(childRelative);
    const childStats = await stableLstat(childAbsolute, childPath);

    if (isSelfManifest(childRelative)) {
      assertSupportedEntry(childStats, childPath);
      if (!childStats.isFile()) {
        fail("unsupported_entry", "the manifest self-exclusion path must be a regular file");
      }
      if (childStats.size > BigInt(MAXIMUM_CANONICAL_MANIFEST_BYTES)) {
        fail("resource_limit", "the manifest self-exclusion file exceeds the byte limit");
      }
      context.stabilityChecks.push({
        absoluteBytes: Buffer.from(childAbsolute),
        relativePath: childPath,
        stats: childStats,
      });
      continue;
    }

    assertSupportedEntry(childStats, childPath);
    if (childStats.isDirectory()) {
      await visitDirectory(context, childAbsolute, childRelative, childStats);
    } else {
      const file = await hashRegularFile(
        context,
        childAbsolute,
        childPath,
        childStats,
      );
      addEntry(context, {
        kind: "file",
        path: childPath,
        pathBytes: Buffer.from(childRelative),
        mode: permissionMode(childStats),
        size: file.size,
        sha256: file.sha256,
      });
      context.stabilityChecks.push({
        absoluteBytes: Buffer.from(childAbsolute),
        relativePath: childPath,
        stats: file.stableStats,
      });
    }
  }

  const finalStats = await stableLstat(absoluteBytes, relativePath);
  requireStableEntry(initialStats, finalStats, relativePath);
  context.stabilityChecks.push({
    absoluteBytes: Buffer.from(absoluteBytes),
    relativePath,
    stats: finalStats,
  });
}

async function verifyStableSnapshot(stabilityChecks) {
  for (const entry of stabilityChecks) {
    const currentStats = await stableLstat(entry.absoluteBytes, entry.relativePath);
    requireStableEntry(entry.stats, currentStats, entry.relativePath);
  }
}

function unsignedIntegerBuffer(value, byteLength, label) {
  const maximum = (1n << BigInt(byteLength * 8)) - 1n;
  const integer = typeof value === "bigint" ? value : BigInt(value);
  if (integer < 0n || integer > maximum) {
    fail("resource_limit", `${label} cannot be represented canonically`);
  }
  const buffer = Buffer.alloc(byteLength);
  if (byteLength === 2) {
    buffer.writeUInt16BE(Number(integer));
  } else if (byteLength === 4) {
    buffer.writeUInt32BE(Number(integer));
  } else if (byteLength === 8) {
    buffer.writeBigUInt64BE(integer);
  } else {
    throw new Error("unsupported canonical integer width");
  }
  return buffer;
}

function canonicalRecord(entry) {
  const fields = [
    Buffer.of(entry.kind === "directory" ? RECORD_KIND_DIRECTORY : RECORD_KIND_FILE),
    unsignedIntegerBuffer(entry.pathBytes.length, 4, "path length"),
    entry.pathBytes,
    unsignedIntegerBuffer(entry.mode, 2, "permission mode"),
  ];
  if (entry.kind === "file") {
    fields.push(
      unsignedIntegerBuffer(entry.size, 8, "file size"),
      Buffer.from(entry.sha256, "hex"),
    );
  }
  const payload = Buffer.concat(fields);
  return Buffer.concat([
    unsignedIntegerBuffer(payload.length, 8, "record length"),
    payload,
  ]);
}

function canonicalManifest(entries) {
  const sortedEntries = [...entries].sort((left, right) =>
    Buffer.compare(left.pathBytes, right.pathBytes),
  );
  const records = sortedEntries.map(canonicalRecord);
  const bytes = Buffer.concat([
    MANIFEST_MAGIC,
    unsignedIntegerBuffer(DEPLOYMENT_MANIFEST_VERSION, 4, "manifest version"),
    unsignedIntegerBuffer(records.length, 8, "record count"),
    ...records,
  ]);
  if (bytes.length > MAXIMUM_CANONICAL_MANIFEST_BYTES) {
    fail("resource_limit", "canonical deployment manifest exceeds the byte limit");
  }
  return { bytes, entries: sortedEntries };
}

export async function createDeploymentManifest(root) {
  const canonicalRoot = await requireCanonicalRoot(root);
  const context = {
    entries: [],
    entryCount: 0,
    totalFileBytes: 0n,
    canonicalByteCount: MANIFEST_MAGIC.length + 4 + 8,
    stabilityChecks: [],
  };
  await visitDirectory(context, canonicalRoot.bytes, Buffer.alloc(0), canonicalRoot.stats);
  await verifyStableSnapshot(context.stabilityChecks);
  const canonical = canonicalManifest(context.entries);
  return {
    version: DEPLOYMENT_MANIFEST_VERSION,
    rootDigest: createHash("sha256").update(canonical.bytes).digest("hex"),
    canonicalBytes: canonical.bytes,
    records: canonical.entries.map((entry) => {
      const record = {
        kind: entry.kind,
        path: entry.path,
        mode: entry.mode,
      };
      if (entry.kind === "file") {
        record.size = entry.size;
        record.sha256 = entry.sha256;
      }
      return Object.freeze(record);
    }),
  };
}

export async function verifyDeploymentManifest(root, expectedRootDigest) {
  if (typeof expectedRootDigest !== "string" || !sha256Pattern.test(expectedRootDigest)) {
    fail("invalid_digest", "expected deployment root digest must be lowercase SHA-256");
  }
  const manifest = await createDeploymentManifest(root);
  const expected = Buffer.from(expectedRootDigest, "hex");
  const actual = Buffer.from(manifest.rootDigest, "hex");
  if (!timingSafeEqual(actual, expected)) {
    fail("digest_mismatch", "deployment root digest does not match the allowlist");
  }
  return manifest;
}

export async function verifyDeclaredLoadedFiles(root, expectedRootDigest, loadedFilePaths) {
  if (!Array.isArray(loadedFilePaths) || loadedFilePaths.length === 0) {
    fail("containment", "loaded file inventory must be a nonempty array");
  }
  const manifest = await verifyDeploymentManifest(root, expectedRootDigest);
  const canonicalRoot = await requireCanonicalRoot(root);
  const recordsByPath = new Map(manifest.records.map((record) => [record.path, record]));
  const seenLoadedPaths = new Set();

  for (const loadedFilePath of loadedFilePaths) {
    const candidate = asPathString(loadedFilePath);
    if (!path.isAbsolute(candidate) || path.normalize(candidate) !== candidate) {
      fail("containment", "declared loaded file must use a canonical absolute path");
    }
    let canonicalLoadedFile;
    try {
      canonicalLoadedFile = await realpath(candidate);
    } catch {
      fail("containment", "declared loaded file is unavailable");
    }
    if (canonicalLoadedFile !== candidate) {
      fail("containment", "declared loaded file must not traverse a symbolic link");
    }
    if (seenLoadedPaths.has(canonicalLoadedFile)) {
      fail("containment", "loaded file inventory contains a duplicate path");
    }
    seenLoadedPaths.add(canonicalLoadedFile);

    const relative = path.relative(canonicalRoot.path, canonicalLoadedFile);
    if (
      relative === "" ||
      relative === ".." ||
      relative.startsWith(`..${path.sep}`) ||
      path.isAbsolute(relative)
    ) {
      fail("containment", "declared loaded file is outside the deployment root");
    }
    const manifestPath = relative.split(path.sep).join("/");
    const record = recordsByPath.get(manifestPath);
    if (record?.kind !== "file") {
      fail("containment", "declared loaded file is absent from the deployment manifest");
    }
  }

  return manifest;
}
