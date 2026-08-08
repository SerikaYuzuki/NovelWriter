import { Buffer } from "node:buffer";
import { createHash } from "node:crypto";
import { constants as fileConstants } from "node:fs";
import {
  lstat,
  mkdir,
  open,
  opendir,
  realpath,
} from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { TextDecoder } from "node:util";

import {
  DEPLOYMENT_MANIFEST_SELF_PATH,
  DeploymentManifestError,
  MAXIMUM_DEPLOYMENT_FILE_BYTES,
  MAXIMUM_DEPLOYMENT_TOTAL_FILE_BYTES,
  createDeploymentManifest,
  verifyDeploymentManifest,
} from "./deployment-manifest.mjs";

// Build-time identity primitive only. A mutable same-user source/destination,
// native pre-spawn verification, and the verify-to-use race remain later Gates.
// Nothing returned by this module authorizes an executable path.

export const CODEX_DEPLOYMENT_PACKAGER_VERSION = 1;

const ROOT_MODE = 0o700;
const DIRECTORY_MODE = 0o755;
const REGULAR_FILE_MODE = 0o644;
const EXECUTABLE_FILE_MODE = 0o755;
const COPY_CHUNK_BYTES = 64 * 1_024;
const MAXIMUM_SCOPED_DIRECTORY_ENTRIES = 1_024;
const MAXIMUM_IDENTITY_JSON_BYTES = 1 * 1_024 * 1_024;
const utf8Decoder = new TextDecoder("utf-8", { fatal: true });

const pinnedIdentity = Object.freeze({
  sdkVersion: "0.147.0",
  sdkIntegrity:
    "sha512-nJL0maDBZy31uEArs+u46tW22veNdHjfs96AGaFTnI3jF+g8U+a422uaPiDZwEKmyxcNwStTRz6sIh6C7XxGFQ==",
  cliVersion: "0.147.0",
  cliIntegrity:
    "sha512-EQLEXecAG2ptxI7UpBMo2TR/ga5596/c/OsYF/0LoUDh5JANZ7IoGqlzBEWbuEVQ76JePIbtTW/ihCkp1a7Z3w==",
  platformVersion: "0.147.0-darwin-arm64",
  platformIntegrity:
    "sha512-BEUVkiOW7kLcRyrMLfAr/h9wF8sRVJyZDy6OHtVn6QGDXiv3BvAZVTY1Pu9xF7KdIdkYXbp4uayN0aDQQaAUJw==",
});

const fixedFileSpecs = [
  ["package.json", REGULAR_FILE_MODE],
  ["package-lock.json", REGULAR_FILE_MODE],
  ["src/main.mjs", REGULAR_FILE_MODE],
  ["src/protocol.mjs", REGULAR_FILE_MODE],
  ["src/session.mjs", REGULAR_FILE_MODE],
  ["node_modules/@openai/codex-sdk/LICENSE", REGULAR_FILE_MODE],
  ["node_modules/@openai/codex-sdk/README.md", REGULAR_FILE_MODE],
  ["node_modules/@openai/codex-sdk/dist/index.d.ts", REGULAR_FILE_MODE],
  ["node_modules/@openai/codex-sdk/dist/index.js", REGULAR_FILE_MODE],
  ["node_modules/@openai/codex-sdk/dist/index.js.map", REGULAR_FILE_MODE],
  ["node_modules/@openai/codex-sdk/package.json", REGULAR_FILE_MODE],
  ["node_modules/@openai/codex/README.md", REGULAR_FILE_MODE],
  ["node_modules/@openai/codex/bin/codex.js", EXECUTABLE_FILE_MODE],
  ["node_modules/@openai/codex/package.json", REGULAR_FILE_MODE],
  ["node_modules/@openai/codex-darwin-arm64/README.md", REGULAR_FILE_MODE],
  ["node_modules/@openai/codex-darwin-arm64/package.json", REGULAR_FILE_MODE],
  [
    "node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex-package.json",
    REGULAR_FILE_MODE,
  ],
  [
    "node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex",
    EXECUTABLE_FILE_MODE,
  ],
  [
    "node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex-code-mode-host",
    EXECUTABLE_FILE_MODE,
  ],
  [
    "node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex-path/rg",
    EXECUTABLE_FILE_MODE,
  ],
  [
    "node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex-resources/zsh/bin/zsh",
    EXECUTABLE_FILE_MODE,
  ],
];

export const CODEX_DEPLOYMENT_FILE_ALLOWLIST_V1 = Object.freeze(
  fixedFileSpecs.map(([relativePath, mode]) =>
    Object.freeze({ relativePath, mode }),
  ),
);

function derivedDirectorySpecs() {
  const paths = new Set();
  for (const file of CODEX_DEPLOYMENT_FILE_ALLOWLIST_V1) {
    const components = file.relativePath.split("/");
    components.pop();
    while (components.length > 0) {
      paths.add(components.join("/"));
      components.pop();
    }
  }
  return [...paths]
    .sort((left, right) => {
      const depth = left.split("/").length - right.split("/").length;
      return depth === 0
        ? Buffer.compare(Buffer.from(left), Buffer.from(right))
        : depth;
    })
    .map((relativePath) => Object.freeze({ relativePath, mode: DIRECTORY_MODE }));
}

export const CODEX_DEPLOYMENT_DIRECTORY_ALLOWLIST_V1 = Object.freeze(
  derivedDirectorySpecs(),
);

const fixedPackageRoots = Object.freeze([
  "node_modules/@openai/codex-sdk",
  "node_modules/@openai/codex",
  "node_modules/@openai/codex-darwin-arm64",
]);

export class DeploymentPackagerError extends Error {
  constructor(
    code,
    message,
    { partialDestinationRetained = false, underlyingCode = null } = {},
  ) {
    super(message);
    this.name = "DeploymentPackagerError";
    this.code = code;
    this.partialDestinationRetained = partialDestinationRetained;
    this.underlyingCode = underlyingCode;
  }
}

function fail(code, message) {
  throw new DeploymentPackagerError(code, message);
}

function asPathString(value, code, label) {
  if (value instanceof URL) {
    if (value.protocol !== "file:") {
      fail(code, `${label} URL must use the file protocol`);
    }
    return fileURLToPath(value);
  }
  if (typeof value !== "string" || value.length === 0) {
    fail(code, `${label} must be a nonempty absolute path`);
  }
  return value;
}

function relativeAbsolutePath(root, relativePath) {
  return path.join(root, ...relativePath.split("/"));
}

function permissionMode(stats) {
  return Number(stats.mode & 0o777n);
}

function validateSafeMode(stats, label) {
  if ((stats.mode & 0o7000n) !== 0n || (stats.mode & 0o022n) !== 0n) {
    fail("source_invalid_mode", `${label} has unsafe permission bits`);
  }
}

function validateSourceEntry(stats, label) {
  if (stats.isSymbolicLink()) {
    fail("source_symlink", `${label} is a symbolic link`);
  }
  if (!stats.isDirectory() && !stats.isFile()) {
    fail("source_unsupported_entry", `${label} is not a regular file or directory`);
  }
  if (stats.isFile() && stats.nlink !== 1n) {
    fail("source_hardlink", `${label} is a hard-linked regular file`);
  }
  validateSafeMode(stats, label);
}

function requireExpectedEntry(stats, spec, kind) {
  validateSourceEntry(stats, spec.relativePath);
  if (
    (kind === "directory" && !stats.isDirectory()) ||
    (kind === "file" && !stats.isFile())
  ) {
    fail("source_unsupported_entry", `${spec.relativePath} has the wrong entry type`);
  }
  if (permissionMode(stats) !== spec.mode) {
    fail("source_mode_mismatch", `${spec.relativePath} has an unexpected mode`);
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
  const expected = statFingerprint(left);
  const actual = statFingerprint(right);
  return expected.every((value, index) => value === actual[index]);
}

async function stableLstat(absolutePath, label, missingCode = "source_missing") {
  try {
    return await lstat(absolutePath, { bigint: true });
  } catch (error) {
    if (error?.code === "ENOENT") {
      fail(missingCode, `${label} is missing`);
    }
    fail("source_unavailable", `${label} cannot be inspected`);
  }
}

async function requireCanonicalSourceRoot(value) {
  const candidate = asPathString(value, "invalid_source_root", "source root");
  if (!path.isAbsolute(candidate) || path.normalize(candidate) !== candidate) {
    fail("invalid_source_root", "source root must be absolute and normalized");
  }

  let canonical;
  let stats;
  try {
    canonical = await realpath(candidate);
    stats = await lstat(candidate, { bigint: true });
  } catch {
    fail("invalid_source_root", "source root is unavailable");
  }
  if (canonical !== candidate || !stats.isDirectory() || stats.isSymbolicLink()) {
    fail("invalid_source_root", "source root must be a canonical directory");
  }
  validateSafeMode(stats, "source root");
  return candidate;
}

async function destinationPlan(value, sourceRoot) {
  const candidate = asPathString(
    value,
    "invalid_destination_root",
    "destination root",
  );
  if (!path.isAbsolute(candidate) || path.normalize(candidate) !== candidate) {
    fail("invalid_destination_root", "destination root must be absolute and normalized");
  }

  const parent = path.dirname(candidate);
  const basename = path.basename(candidate);
  const hasCanonicalSpelling =
    basename.length > 0 && path.join(parent, basename) === candidate;
  if (
    !hasCanonicalSpelling ||
    basename === "." ||
    basename === ".." ||
    basename.includes("\0")
  ) {
    fail("invalid_destination_root", "destination root has an invalid final component");
  }

  let canonicalParent;
  let parentStats;
  try {
    canonicalParent = await realpath(parent);
    parentStats = await lstat(parent, { bigint: true });
  } catch {
    fail("invalid_destination_root", "destination parent is unavailable");
  }
  if (
    canonicalParent !== parent ||
    !parentStats.isDirectory() ||
    parentStats.isSymbolicLink()
  ) {
    fail("invalid_destination_root", "destination parent must be canonical");
  }
  validateSafeMode(parentStats, "destination parent");

  const sourceToDestination = path.relative(sourceRoot, candidate);
  const destinationToSource = path.relative(candidate, sourceRoot);
  const isContained = (relative) =>
    relative === "" ||
    (!relative.startsWith(`..${path.sep}`) && relative !== ".." && !path.isAbsolute(relative));
  if (isContained(sourceToDestination) || isContained(destinationToSource)) {
    fail("invalid_destination_root", "source and destination roots must not overlap");
  }

  try {
    await lstat(candidate);
    fail("destination_exists", "destination root already exists");
  } catch (error) {
    if (error instanceof DeploymentPackagerError) {
      throw error;
    }
    if (error?.code !== "ENOENT") {
      fail("invalid_destination_root", "destination root cannot be inspected");
    }
  }
  return candidate;
}

function decodeDirectoryName(nameBytes) {
  let name;
  try {
    name = utf8Decoder.decode(nameBytes);
  } catch {
    fail("source_extra", "source contains a non-UTF-8 path component");
  }
  if (
    name.length === 0 ||
    name === "." ||
    name === ".." ||
    name.includes("/") ||
    name.includes("\0") ||
    !Buffer.from(name, "utf8").equals(nameBytes)
  ) {
    fail("source_extra", "source contains a noncanonical path component");
  }
  return name;
}

async function scanScopedHiddenEntries(sourceRoot, relative, allowedHidden) {
  const absolute = relativeAbsolutePath(sourceRoot, relative);
  let directory;
  try {
    directory = await opendir(absolute, { encoding: "buffer", bufferSize: 32 });
  } catch {
    fail("source_unavailable", `${relative || "source root"} cannot be enumerated`);
  }

  let entryCount = 0;
  try {
    for await (const dirent of directory) {
      entryCount += 1;
      if (entryCount > MAXIMUM_SCOPED_DIRECTORY_ENTRIES) {
        fail("source_resource_limit", `${relative || "source root"} has too many entries`);
      }
      const component = decodeDirectoryName(Buffer.from(dirent.name));
      if (!component.startsWith(".")) {
        continue;
      }
      const expected = allowedHidden.get(component);
      const childRelative = relative ? `${relative}/${component}` : component;
      if (!expected) {
        fail("source_extra", `${childRelative} is an unexpected hidden entry`);
      }
      const stats = await stableLstat(
        relativeAbsolutePath(sourceRoot, childRelative),
        childRelative,
      );
      requireExpectedEntry(
        stats,
        { relativePath: childRelative, mode: expected.mode },
        expected.kind,
      );
    }
  } finally {
    await directory.close().catch(() => {});
  }
}

async function validateScopedHiddenEntries(sourceRoot) {
  const noHiddenEntries = new Map();
  await scanScopedHiddenEntries(sourceRoot, "", noHiddenEntries);
  await scanScopedHiddenEntries(sourceRoot, "src", noHiddenEntries);
  await scanScopedHiddenEntries(
    sourceRoot,
    "node_modules",
    new Map([
      [".bin", { kind: "directory", mode: DIRECTORY_MODE }],
      [".package-lock.json", { kind: "file", mode: REGULAR_FILE_MODE }],
    ]),
  );
  await scanScopedHiddenEntries(sourceRoot, "node_modules/@openai", noHiddenEntries);
}

function packageExpectedEntries(packageRoot) {
  const prefix = `${packageRoot}/`;
  const expected = new Map();
  for (const spec of CODEX_DEPLOYMENT_DIRECTORY_ALLOWLIST_V1) {
    if (spec.relativePath.startsWith(prefix)) {
      expected.set(spec.relativePath.slice(prefix.length), {
        kind: "directory",
        mode: spec.mode,
      });
    }
  }
  for (const spec of CODEX_DEPLOYMENT_FILE_ALLOWLIST_V1) {
    if (spec.relativePath.startsWith(prefix)) {
      expected.set(spec.relativePath.slice(prefix.length), {
        kind: "file",
        mode: spec.mode,
      });
    }
  }
  return expected;
}

async function scanExactPackageTree(sourceRoot, packageRoot) {
  const expected = packageExpectedEntries(packageRoot);
  const seen = new Set();

  async function visit(absolute, relative = "") {
    let directory;
    try {
      directory = await opendir(absolute, { encoding: "buffer", bufferSize: 32 });
    } catch {
      fail("source_unavailable", `${packageRoot} cannot be enumerated`);
    }
    try {
      for await (const dirent of directory) {
        const component = decodeDirectoryName(Buffer.from(dirent.name));
        const childRelative = relative ? `${relative}/${component}` : component;
        const spec = expected.get(childRelative);
        if (!spec) {
          fail("source_extra", `${packageRoot}/${childRelative} is not allowlisted`);
        }
        const fullRelative = `${packageRoot}/${childRelative}`;
        const childAbsolute = relativeAbsolutePath(sourceRoot, fullRelative);
        const stats = await stableLstat(childAbsolute, fullRelative);
        requireExpectedEntry(
          stats,
          { relativePath: fullRelative, mode: spec.mode },
          spec.kind,
        );
        seen.add(childRelative);
        if (spec.kind === "directory") {
          await visit(childAbsolute, childRelative);
        }
      }
    } finally {
      await directory.close().catch(() => {});
    }
  }

  await visit(relativeAbsolutePath(sourceRoot, packageRoot));
  for (const relativePath of expected.keys()) {
    if (!seen.has(relativePath)) {
      fail("source_missing", `${packageRoot}/${relativePath} is missing`);
    }
  }
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

async function readStableIdentityJSON(sourceRoot, relativePath, expectedStats) {
  if (expectedStats.size > BigInt(MAXIMUM_IDENTITY_JSON_BYTES)) {
    fail("source_identity_mismatch", `${relativePath} exceeds the identity byte limit`);
  }
  const absolutePath = relativeAbsolutePath(sourceRoot, relativePath);
  let handle;
  try {
    handle = await open(
      absolutePath,
      fileConstants.O_RDONLY | fileConstants.O_NOFOLLOW,
    );
    const openedStats = await handle.stat({ bigint: true });
    if (!sameFingerprint(expectedStats, openedStats)) {
      fail("source_changed", `${relativePath} changed before identity validation`);
    }
    const expectedSize = Number(openedStats.size);
    const bytes = Buffer.allocUnsafe(expectedSize);
    let position = 0;
    while (position < expectedSize) {
      const { bytesRead } = await handle.read(
        bytes,
        position,
        expectedSize - position,
        position,
      );
      if (bytesRead === 0) {
        fail("source_changed", `${relativePath} became shorter during identity validation`);
      }
      position += bytesRead;
    }
    const trailing = Buffer.allocUnsafe(1);
    const { bytesRead: trailingBytes } = await handle.read(
      trailing,
      0,
      1,
      expectedSize,
    );
    if (trailingBytes !== 0) {
      fail("source_changed", `${relativePath} became longer during identity validation`);
    }
    const finalStats = await handle.stat({ bigint: true });
    const pathStats = await stableLstat(absolutePath, relativePath);
    if (
      !sameFingerprint(openedStats, finalStats) ||
      !sameFingerprint(finalStats, pathStats)
    ) {
      fail("source_changed", `${relativePath} changed during identity validation`);
    }
    let text;
    try {
      text = utf8Decoder.decode(bytes);
    } catch {
      fail("source_identity_mismatch", `${relativePath} is not valid UTF-8 JSON`);
    }
    let value;
    try {
      value = JSON.parse(text);
    } catch {
      fail("source_identity_mismatch", `${relativePath} is not valid JSON`);
    }
    if (!isRecord(value)) {
      fail("source_identity_mismatch", `${relativePath} must contain a JSON object`);
    }
    return value;
  } catch (error) {
    if (error instanceof DeploymentPackagerError) {
      throw error;
    }
    fail("source_identity_mismatch", `${relativePath} could not be validated`);
  } finally {
    await handle?.close().catch(() => {});
  }
}

function requireIdentity(condition, label) {
  if (!condition) {
    fail("source_identity_mismatch", `${label} does not match the pinned metadata`);
  }
}

async function validatePinnedPackageMetadata(sourceRoot, fileStats) {
  const rootPackage = await readStableIdentityJSON(
    sourceRoot,
    "package.json",
    fileStats.get("package.json"),
  );
  requireIdentity(
    rootPackage.dependencies?.["@openai/codex-sdk"] === pinnedIdentity.sdkVersion,
    "root package SDK version",
  );

  const lock = await readStableIdentityJSON(
    sourceRoot,
    "package-lock.json",
    fileStats.get("package-lock.json"),
  );
  requireIdentity(lock.lockfileVersion === 3 && isRecord(lock.packages), "lockfile");
  requireIdentity(
    lock.packages[""]?.dependencies?.["@openai/codex-sdk"] ===
      pinnedIdentity.sdkVersion,
    "lockfile root SDK version",
  );
  const lockedSDK = lock.packages["node_modules/@openai/codex-sdk"];
  requireIdentity(
    lockedSDK?.version === pinnedIdentity.sdkVersion &&
      lockedSDK?.integrity === pinnedIdentity.sdkIntegrity,
    "locked SDK identity",
  );
  const lockedCLI = lock.packages["node_modules/@openai/codex"];
  requireIdentity(
    lockedCLI?.version === pinnedIdentity.cliVersion &&
      lockedCLI?.integrity === pinnedIdentity.cliIntegrity,
    "locked CLI identity",
  );
  const lockedPlatform =
    lock.packages["node_modules/@openai/codex-darwin-arm64"];
  requireIdentity(
    lockedPlatform?.name === "@openai/codex" &&
      lockedPlatform?.version === pinnedIdentity.platformVersion &&
      lockedPlatform?.integrity === pinnedIdentity.platformIntegrity,
    "locked platform CLI identity",
  );

  const sdkPackage = await readStableIdentityJSON(
    sourceRoot,
    "node_modules/@openai/codex-sdk/package.json",
    fileStats.get("node_modules/@openai/codex-sdk/package.json"),
  );
  requireIdentity(
    sdkPackage.name === "@openai/codex-sdk" &&
      sdkPackage.version === pinnedIdentity.sdkVersion &&
      sdkPackage.dependencies?.["@openai/codex"] === pinnedIdentity.cliVersion,
    "installed SDK package identity",
  );

  const cliPackage = await readStableIdentityJSON(
    sourceRoot,
    "node_modules/@openai/codex/package.json",
    fileStats.get("node_modules/@openai/codex/package.json"),
  );
  requireIdentity(
    cliPackage.name === "@openai/codex" &&
      cliPackage.version === pinnedIdentity.cliVersion &&
      cliPackage.optionalDependencies?.["@openai/codex-darwin-arm64"] ===
        `npm:@openai/codex@${pinnedIdentity.platformVersion}`,
    "installed CLI package identity",
  );

  const platformPackagePath =
    "node_modules/@openai/codex-darwin-arm64/package.json";
  const platformPackage = await readStableIdentityJSON(
    sourceRoot,
    platformPackagePath,
    fileStats.get(platformPackagePath),
  );
  requireIdentity(
    platformPackage.name === "@openai/codex" &&
      platformPackage.version === pinnedIdentity.platformVersion &&
      JSON.stringify(platformPackage.os) === JSON.stringify(["darwin"]) &&
      JSON.stringify(platformPackage.cpu) === JSON.stringify(["arm64"]),
    "installed platform CLI package identity",
  );

  const layoutPath =
    "node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex-package.json";
  const layout = await readStableIdentityJSON(
    sourceRoot,
    layoutPath,
    fileStats.get(layoutPath),
  );
  requireIdentity(
    layout.layoutVersion === 1 &&
      layout.version === pinnedIdentity.cliVersion &&
      layout.target === "aarch64-apple-darwin" &&
      layout.variant === "codex" &&
      layout.entrypoint === "bin/codex" &&
      layout.resourcesDir === "codex-resources" &&
      layout.pathDir === "codex-path",
    "installed platform CLI layout",
  );
}

async function validateSourceLayout(sourceRoot) {
  await validateScopedHiddenEntries(sourceRoot);

  for (const spec of CODEX_DEPLOYMENT_DIRECTORY_ALLOWLIST_V1) {
    const stats = await stableLstat(
      relativeAbsolutePath(sourceRoot, spec.relativePath),
      spec.relativePath,
    );
    requireExpectedEntry(stats, spec, "directory");
  }

  const fileStats = new Map();
  let totalFileBytes = 0n;
  for (const spec of CODEX_DEPLOYMENT_FILE_ALLOWLIST_V1) {
    const stats = await stableLstat(
      relativeAbsolutePath(sourceRoot, spec.relativePath),
      spec.relativePath,
    );
    requireExpectedEntry(stats, spec, "file");
    if (stats.size > BigInt(MAXIMUM_DEPLOYMENT_FILE_BYTES)) {
      fail("source_resource_limit", `${spec.relativePath} exceeds the file byte limit`);
    }
    totalFileBytes += stats.size;
    if (totalFileBytes > BigInt(MAXIMUM_DEPLOYMENT_TOTAL_FILE_BYTES)) {
      fail("source_resource_limit", "allowlisted source files exceed the byte limit");
    }
    fileStats.set(spec.relativePath, stats);
  }

  for (const packageRoot of fixedPackageRoots) {
    await scanExactPackageTree(sourceRoot, packageRoot);
  }
  await validatePinnedPackageMetadata(sourceRoot, fileStats);
  return fileStats;
}

async function createDestinationRoot(destinationRoot) {
  try {
    await mkdir(destinationRoot, { mode: ROOT_MODE });
  } catch (error) {
    if (error?.code === "EEXIST") {
      fail("destination_exists", "destination root already exists");
    }
    fail("destination_create_failed", "destination root could not be created");
  }
  try {
    return await fixCreatedDirectory(
      destinationRoot,
      ROOT_MODE,
      "destination root",
    );
  } catch (error) {
    throw retainedPartialDestinationError(error);
  }
}

async function fixCreatedDirectory(absolutePath, mode, label) {
  let handle;
  try {
    handle = await open(
      absolutePath,
      fileConstants.O_RDONLY |
        fileConstants.O_DIRECTORY |
        fileConstants.O_NOFOLLOW,
    );
    await handle.chmod(mode);
    const stats = await handle.stat({ bigint: true });
    if (
      !stats.isDirectory() ||
      stats.isSymbolicLink() ||
      permissionMode(stats) !== mode
    ) {
      fail("destination_create_failed", `${label} has an unexpected identity`);
    }
    return stats;
  } catch (error) {
    if (error instanceof DeploymentPackagerError) {
      throw error;
    }
    fail("destination_create_failed", `${label} could not be fixed to canonical mode`);
  } finally {
    await handle?.close().catch(() => {});
  }
}

async function createDestinationDirectories(destinationRoot) {
  for (const spec of CODEX_DEPLOYMENT_DIRECTORY_ALLOWLIST_V1) {
    const absolute = relativeAbsolutePath(destinationRoot, spec.relativePath);
    try {
      await mkdir(absolute, { mode: spec.mode });
      await fixCreatedDirectory(absolute, spec.mode, spec.relativePath);
    } catch (error) {
      if (error instanceof DeploymentPackagerError) {
        throw error;
      }
      fail("destination_create_failed", `${spec.relativePath} could not be created`);
    }
  }
}

async function writeAll(handle, buffer, length, position) {
  let written = 0;
  while (written < length) {
    const result = await handle.write(
      buffer,
      written,
      length - written,
      position + written,
    );
    if (result.bytesWritten === 0) {
      fail("copy_failed", "destination write made no progress");
    }
    written += result.bytesWritten;
  }
}

async function copyAllowlistedFile(
  sourceRoot,
  destinationRoot,
  spec,
  expectedSourceStats,
) {
  const source = relativeAbsolutePath(sourceRoot, spec.relativePath);
  const destination = relativeAbsolutePath(destinationRoot, spec.relativePath);
  let sourceHandle;
  let destinationHandle;
  try {
    sourceHandle = await open(
      source,
      fileConstants.O_RDONLY | fileConstants.O_NOFOLLOW,
    );
    const openedSourceStats = await sourceHandle.stat({ bigint: true });
    requireExpectedEntry(openedSourceStats, spec, "file");
    if (!sameFingerprint(expectedSourceStats, openedSourceStats)) {
      fail("source_changed", `${spec.relativePath} changed before copying`);
    }

    destinationHandle = await open(
      destination,
      fileConstants.O_WRONLY |
        fileConstants.O_CREAT |
        fileConstants.O_EXCL |
        fileConstants.O_NOFOLLOW,
      spec.mode,
    );
    await destinationHandle.chmod(spec.mode);

    const buffer = Buffer.allocUnsafe(COPY_CHUNK_BYTES);
    const sourceDigest = createHash("sha256");
    const expectedSize = Number(openedSourceStats.size);
    let position = 0;
    while (position < expectedSize) {
      const requested = Math.min(buffer.length, expectedSize - position);
      const { bytesRead } = await sourceHandle.read(buffer, 0, requested, position);
      if (bytesRead === 0) {
        fail("source_changed", `${spec.relativePath} became shorter while copying`);
      }
      sourceDigest.update(buffer.subarray(0, bytesRead));
      await writeAll(destinationHandle, buffer, bytesRead, position);
      position += bytesRead;
    }
    const trailing = Buffer.allocUnsafe(1);
    const { bytesRead: trailingBytes } = await sourceHandle.read(
      trailing,
      0,
      1,
      expectedSize,
    );
    if (trailingBytes !== 0) {
      fail("source_changed", `${spec.relativePath} became longer while copying`);
    }

    const finalSourceStats = await sourceHandle.stat({ bigint: true });
    const sourcePathStats = await stableLstat(source, spec.relativePath);
    if (
      !sameFingerprint(openedSourceStats, finalSourceStats) ||
      !sameFingerprint(finalSourceStats, sourcePathStats)
    ) {
      fail("source_changed", `${spec.relativePath} changed while copying`);
    }

    await destinationHandle.sync();
    const destinationStats = await destinationHandle.stat({ bigint: true });
    if (
      !destinationStats.isFile() ||
      destinationStats.nlink !== 1n ||
      destinationStats.size !== openedSourceStats.size ||
      permissionMode(destinationStats) !== spec.mode
    ) {
      fail("copy_failed", `${spec.relativePath} was not copied exactly`);
    }
    return Object.freeze({
      size: expectedSize,
      sha256: sourceDigest.digest("hex"),
    });
  } catch (error) {
    if (error instanceof DeploymentPackagerError) {
      throw error;
    }
    fail("copy_failed", `${spec.relativePath} could not be copied`);
  } finally {
    await destinationHandle?.close().catch(() => {});
    await sourceHandle?.close().catch(() => {});
  }
}

function expectedOutputRecords() {
  const expected = new Map([["", { kind: "directory", mode: ROOT_MODE }]]);
  for (const spec of CODEX_DEPLOYMENT_DIRECTORY_ALLOWLIST_V1) {
    expected.set(spec.relativePath, { kind: "directory", mode: spec.mode });
  }
  for (const spec of CODEX_DEPLOYMENT_FILE_ALLOWLIST_V1) {
    expected.set(spec.relativePath, { kind: "file", mode: spec.mode });
  }
  return expected;
}

function requireExactOutputRecords(records, copiedFiles) {
  const expected = expectedOutputRecords();
  if (records.length !== expected.size) {
    fail("destination_extra", "destination does not have the exact allowlisted shape");
  }
  for (const record of records) {
    const spec = expected.get(record.path);
    if (!spec || spec.kind !== record.kind || spec.mode !== record.mode) {
      fail("destination_extra", "destination contains an unexpected record");
    }
    if (record.kind === "file") {
      const copied = copiedFiles.get(record.path);
      if (
        !copied ||
        record.size !== copied.size ||
        record.sha256 !== copied.sha256
      ) {
        fail("copy_failed", "destination manifest differs from copied source bytes");
      }
    }
  }
}

async function writeSelfManifest(destinationRoot, canonicalBytes) {
  const selfPath = relativeAbsolutePath(
    destinationRoot,
    DEPLOYMENT_MANIFEST_SELF_PATH,
  );
  let handle;
  try {
    handle = await open(
      selfPath,
      fileConstants.O_WRONLY |
        fileConstants.O_CREAT |
        fileConstants.O_EXCL |
        fileConstants.O_NOFOLLOW,
      REGULAR_FILE_MODE,
    );
    await handle.chmod(REGULAR_FILE_MODE);
    await writeAll(handle, canonicalBytes, canonicalBytes.length, 0);
    await handle.sync();
    const stats = await handle.stat({ bigint: true });
    if (
      !stats.isFile() ||
      stats.nlink !== 1n ||
      stats.size !== BigInt(canonicalBytes.length) ||
      permissionMode(stats) !== REGULAR_FILE_MODE
    ) {
      fail("manifest_write_failed", "self manifest was not written exactly");
    }
  } catch (error) {
    if (error instanceof DeploymentPackagerError) {
      throw error;
    }
    fail("manifest_write_failed", "self manifest could not be written");
  } finally {
    await handle?.close().catch(() => {});
  }
}

async function requireDestinationRootIdentity(destinationRoot, createdStats) {
  let current;
  try {
    current = await lstat(destinationRoot, { bigint: true });
  } catch {
    fail("destination_identity_changed", "destination root became unavailable");
  }
  if (
    !current.isDirectory() ||
    current.isSymbolicLink() ||
    current.dev !== createdStats.dev ||
    current.ino !== createdStats.ino
  ) {
    fail("destination_identity_changed", "destination root identity changed");
  }
}

function retainedPartialDestinationError(error) {
  if (
    error instanceof DeploymentPackagerError &&
    error.partialDestinationRetained
  ) {
    return error;
  }
  const underlyingCode =
    error instanceof DeploymentPackagerError ? error.code : "packaging_failed";
  return new DeploymentPackagerError(
    "partial_destination_retained",
    "packaging failed after destination creation; partial output was retained",
    { partialDestinationRetained: true, underlyingCode },
  );
}

function requireUnchangedSourcePlan(initial, final) {
  if (initial.size !== final.size) {
    fail("source_changed", "source allowlist changed while packaging");
  }
  for (const [relativePath, expectedStats] of initial) {
    const actualStats = final.get(relativePath);
    if (!actualStats || !sameFingerprint(expectedStats, actualStats)) {
      fail("source_changed", `${relativePath} changed while packaging`);
    }
  }
}

async function manifestFromExactDestination(destinationRoot, copiedFiles) {
  try {
    const manifest = await createDeploymentManifest(destinationRoot);
    requireExactOutputRecords(manifest.records, copiedFiles);
    return manifest;
  } catch (error) {
    if (error instanceof DeploymentPackagerError) {
      throw error;
    }
    if (error instanceof DeploymentManifestError) {
      fail("manifest_failed", `canonical manifest rejected the output: ${error.code}`);
    }
    fail("manifest_failed", "canonical manifest could not be created");
  }
}

export async function validateCodexDeploymentSourceLayout(sourceValue) {
  const sourceRoot = await requireCanonicalSourceRoot(sourceValue);
  const sourcePlan = await validateSourceLayout(sourceRoot);
  return Object.freeze({
    packagerVersion: CODEX_DEPLOYMENT_PACKAGER_VERSION,
    allowlistedFileCount: sourcePlan.size,
    allowlistedDirectoryCount: CODEX_DEPLOYMENT_DIRECTORY_ALLOWLIST_V1.length,
  });
}

export async function packageCodexDeployment(sourceValue, destinationValue) {
  const sourceRoot = await requireCanonicalSourceRoot(sourceValue);
  const destinationRoot = await destinationPlan(destinationValue, sourceRoot);
  const sourcePlan = await validateSourceLayout(sourceRoot);
  let createdRootStats;
  const copiedFiles = new Map();

  try {
    createdRootStats = await createDestinationRoot(destinationRoot);
    await createDestinationDirectories(destinationRoot);
    for (const spec of CODEX_DEPLOYMENT_FILE_ALLOWLIST_V1) {
      copiedFiles.set(
        spec.relativePath,
        await copyAllowlistedFile(
          sourceRoot,
          destinationRoot,
          spec,
          sourcePlan.get(spec.relativePath),
        ),
      );
    }

    const finalSourcePlan = await validateSourceLayout(sourceRoot);
    requireUnchangedSourcePlan(sourcePlan, finalSourcePlan);
    await requireDestinationRootIdentity(destinationRoot, createdRootStats);

    const candidate = await manifestFromExactDestination(
      destinationRoot,
      copiedFiles,
    );
    await writeSelfManifest(destinationRoot, candidate.canonicalBytes);

    let regenerated;
    try {
      regenerated = await verifyDeploymentManifest(
        destinationRoot,
        candidate.rootDigest,
      );
    } catch (error) {
      if (error instanceof DeploymentManifestError) {
        fail("manifest_failed", `canonical verifier rejected the output: ${error.code}`);
      }
      throw error;
    }
    requireExactOutputRecords(regenerated.records, copiedFiles);
    await requireDestinationRootIdentity(destinationRoot, createdRootStats);
    if (!regenerated.canonicalBytes.equals(candidate.canonicalBytes)) {
      fail("manifest_failed", "canonical manifest bytes changed after self generation");
    }

    // This is an identity candidate only. It does not approve the path for
    // execution and does not close a later native verify-to-spawn race.
    return Object.freeze({
      packagerVersion: CODEX_DEPLOYMENT_PACKAGER_VERSION,
      manifestVersion: candidate.version,
      candidateRootDigest: candidate.rootDigest,
      recordCount: candidate.records.length,
      canonicalManifestByteCount: candidate.canonicalBytes.length,
    });
  } catch (error) {
    if (createdRootStats) {
      throw retainedPartialDestinationError(error);
    }
    if (error instanceof DeploymentPackagerError) {
      throw error;
    }
    fail("packaging_failed", "deployment packaging failed closed");
  }
}
