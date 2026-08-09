import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import {
  chmod,
  link,
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rename,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import test from "node:test";

import {
  DEPLOYMENT_MANIFEST_SELF_PATH,
  DeploymentManifestError,
  createDeploymentManifest,
  verifyDeploymentManifest,
} from "../src/deployment-manifest.mjs";
import {
  CODEX_DEPLOYMENT_DIRECTORY_ALLOWLIST_V1,
  CODEX_DEPLOYMENT_FILE_ALLOWLIST_V1,
  DeploymentPackagerError,
  packageCodexDeployment,
  validateCodexDeploymentSourceLayout,
} from "../src/deployment-packager.mjs";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const execFileAsync = promisify(execFile);

function errorCode(code) {
  return (error) => error instanceof DeploymentPackagerError && error.code === code;
}

function retainedPartialError(underlyingCode) {
  const allowed = Array.isArray(underlyingCode) ? underlyingCode : [underlyingCode];
  return (error) =>
    error instanceof DeploymentPackagerError &&
    error.code === "partial_destination_retained" &&
    error.partialDestinationRetained === true &&
    allowed.includes(error.underlyingCode);
}

function manifestErrorCode(code) {
  return (error) => error instanceof DeploymentManifestError && error.code === code;
}

function absolute(root, relativePath) {
  return path.join(root, ...relativePath.split("/"));
}

function jsonBytes(value) {
  return Buffer.from(`${JSON.stringify(value, null, 2)}\n`, "utf8");
}

function syntheticFileBytes(relativePath) {
  if (relativePath === "package.json") {
    return jsonBytes({
      name: "fuminiwa-codex-sidecar",
      version: "0.0.0-private",
      private: true,
      type: "module",
      dependencies: { "@openai/codex-sdk": "0.147.0" },
    });
  }
  if (relativePath === "package-lock.json") {
    return jsonBytes({
      name: "fuminiwa-codex-sidecar",
      version: "0.0.0-private",
      lockfileVersion: 3,
      requires: true,
      packages: {
        "": { dependencies: { "@openai/codex-sdk": "0.147.0" } },
        "node_modules/@openai/codex-sdk": {
          version: "0.147.0",
          integrity:
            "sha512-nJL0maDBZy31uEArs+u46tW22veNdHjfs96AGaFTnI3jF+g8U+a422uaPiDZwEKmyxcNwStTRz6sIh6C7XxGFQ==",
        },
        "node_modules/@openai/codex": {
          version: "0.147.0",
          integrity:
            "sha512-EQLEXecAG2ptxI7UpBMo2TR/ga5596/c/OsYF/0LoUDh5JANZ7IoGqlzBEWbuEVQ76JePIbtTW/ihCkp1a7Z3w==",
        },
        "node_modules/@openai/codex-darwin-arm64": {
          name: "@openai/codex",
          version: "0.147.0-darwin-arm64",
          integrity:
            "sha512-BEUVkiOW7kLcRyrMLfAr/h9wF8sRVJyZDy6OHtVn6QGDXiv3BvAZVTY1Pu9xF7KdIdkYXbp4uayN0aDQQaAUJw==",
        },
      },
    });
  }
  if (relativePath === "node_modules/@openai/codex-sdk/package.json") {
    return jsonBytes({
      name: "@openai/codex-sdk",
      version: "0.147.0",
      dependencies: { "@openai/codex": "0.147.0" },
    });
  }
  if (relativePath === "node_modules/@openai/codex/package.json") {
    return jsonBytes({
      name: "@openai/codex",
      version: "0.147.0",
      optionalDependencies: {
        "@openai/codex-darwin-arm64":
          "npm:@openai/codex@0.147.0-darwin-arm64",
      },
    });
  }
  if (
    relativePath === "node_modules/@openai/codex-darwin-arm64/package.json"
  ) {
    return jsonBytes({
      name: "@openai/codex",
      version: "0.147.0-darwin-arm64",
      os: ["darwin"],
      cpu: ["arm64"],
    });
  }
  if (relativePath.endsWith("/codex-package.json")) {
    return jsonBytes({
      layoutVersion: 1,
      version: "0.147.0",
      target: "aarch64-apple-darwin",
      variant: "codex",
      entrypoint: "bin/codex",
      resourcesDir: "codex-resources",
      pathDir: "codex-path",
    });
  }
  return Buffer.from(`synthetic:${relativePath}\n`, "utf8");
}

async function writeFixtureFile(root, relativePath, contents, mode = 0o644) {
  const destination = absolute(root, relativePath);
  await writeFile(destination, contents);
  await chmod(destination, mode);
  return destination;
}

async function createSyntheticDevelopmentRoot(root, { largeFirstFile = false } = {}) {
  await mkdir(root, { mode: 0o700 });
  await chmod(root, 0o700);

  for (const spec of CODEX_DEPLOYMENT_DIRECTORY_ALLOWLIST_V1) {
    const directory = absolute(root, spec.relativePath);
    await mkdir(directory, { mode: spec.mode });
    await chmod(directory, spec.mode);
  }

  const contents = new Map();
  for (const spec of CODEX_DEPLOYMENT_FILE_ALLOWLIST_V1) {
    const bytes =
      largeFirstFile && spec.relativePath === "src/main.mjs"
        ? Buffer.alloc(8 * 1_024 * 1_024, 0x61)
        : syntheticFileBytes(spec.relativePath);
    contents.set(spec.relativePath, bytes);
    await writeFixtureFile(root, spec.relativePath, bytes, spec.mode);
  }

  await mkdir(path.join(root, "test"), { mode: 0o755 });
  await chmod(path.join(root, "test"), 0o755);
  await writeFixtureFile(root, "test/development-only.test.mjs", "not deployed\n");
  await writeFixtureFile(root, "src/deployment-manifest.mjs", "not deployed\n");
  await writeFixtureFile(root, "MANIFEST.md", "development documentation\n");
  await writeFixtureFile(
    root,
    "node_modules/.package-lock.json",
    "development metadata\n",
  );
  await mkdir(path.join(root, "node_modules/.bin"), { mode: 0o755 });
  await chmod(path.join(root, "node_modules/.bin"), 0o755);
  await symlink(
    "../@openai/codex/bin/codex.js",
    path.join(root, "node_modules/.bin/codex"),
  );
  return contents;
}

async function withSyntheticWorkspace(run, options) {
  const { baseDirectory = tmpdir(), ...fixtureOptions } = options ?? {};
  const temporary = await mkdtemp(path.join(baseDirectory, "fuminiwa-packager-v1-"));
  const workspace = await realpath(temporary);
  await chmod(workspace, 0o700);
  const source = path.join(workspace, "development-root");
  const destination = path.join(workspace, "deployment-root");
  const contents = await createSyntheticDevelopmentRoot(source, fixtureOptions);
  try {
    return await run({ workspace, source, destination, contents });
  } finally {
    await rm(workspace, { recursive: true, force: true });
  }
}

async function assertPathMissing(candidate) {
  await assert.rejects(lstat(candidate), (error) => error?.code === "ENOENT");
}

async function waitForPath(candidate) {
  for (let attempt = 0; attempt < 2_000; attempt += 1) {
    try {
      await lstat(candidate);
      return;
    } catch (error) {
      if (error?.code !== "ENOENT") {
        throw error;
      }
    }
    await delay(1);
  }
  assert.fail(`timed out waiting for ${path.basename(candidate)}`);
}

function observePromise(promise) {
  return promise.then(
    (value) => ({ value, error: null }),
    (error) => ({ value: null, error }),
  );
}

test("checked-in npm development root matches the pinned B3 source allowlist and metadata", async () => {
  const developmentRoot = await realpath(path.join(testDirectory, ".."));
  const report = await validateCodexDeploymentSourceLayout(developmentRoot);

  assert.equal(report.packagerVersion, 1);
  assert.equal(
    report.allowlistedFileCount,
    CODEX_DEPLOYMENT_FILE_ALLOWLIST_V1.length,
  );
  assert.equal(
    report.allowlistedDirectoryCount,
    CODEX_DEPLOYMENT_DIRECTORY_ALLOWLIST_V1.length,
  );
  assert.deepEqual(Object.keys(report).sort(), [
    "allowlistedDirectoryCount",
    "allowlistedFileCount",
    "packagerVersion",
  ]);
});

test("fixed allowlist is copied as real files and self manifest is non-authoritative", async () => {
  await withSyntheticWorkspace(async ({ source, destination, contents }) => {
    const result = await packageCodexDeployment(source, destination);
    const manifest = await createDeploymentManifest(destination);

    assert.equal(result.packagerVersion, 1);
    assert.equal(result.manifestVersion, 1);
    assert.equal(result.candidateRootDigest, manifest.rootDigest);
    assert.equal(result.recordCount, manifest.records.length);
    assert.equal(result.canonicalManifestByteCount, manifest.canonicalBytes.length);
    assert.deepEqual(Object.keys(result).sort(), [
      "candidateRootDigest",
      "canonicalManifestByteCount",
      "manifestVersion",
      "packagerVersion",
      "recordCount",
    ]);

    const expectedPaths = [
      "",
      ...CODEX_DEPLOYMENT_DIRECTORY_ALLOWLIST_V1.map((entry) => entry.relativePath),
      ...CODEX_DEPLOYMENT_FILE_ALLOWLIST_V1.map((entry) => entry.relativePath),
    ].sort((left, right) => Buffer.compare(Buffer.from(left), Buffer.from(right)));
    assert.deepEqual(
      manifest.records.map((record) => record.path),
      expectedPaths,
    );

    for (const spec of CODEX_DEPLOYMENT_FILE_ALLOWLIST_V1) {
      const sourcePath = absolute(source, spec.relativePath);
      const destinationPath = absolute(destination, spec.relativePath);
      assert.equal(
        (await readFile(destinationPath)).equals(contents.get(spec.relativePath)),
        true,
      );
      const sourceStats = await lstat(sourcePath, { bigint: true });
      const destinationStats = await lstat(destinationPath, { bigint: true });
      assert.notEqual(destinationStats.ino, sourceStats.ino);
      assert.equal(destinationStats.nlink, 1n);
      assert.equal(Number(destinationStats.mode & 0o777n), spec.mode);
    }

    await assertPathMissing(path.join(destination, "test"));
    await assertPathMissing(path.join(destination, "node_modules/.bin"));
    await assertPathMissing(path.join(destination, "src/deployment-manifest.mjs"));

    const selfPath = path.join(destination, DEPLOYMENT_MANIFEST_SELF_PATH);
    assert.equal((await readFile(selfPath)).equals(manifest.canonicalBytes), true);
    const selfStats = await lstat(selfPath, { bigint: true });
    assert.equal(selfStats.nlink, 1n);
    assert.equal(Number(selfStats.mode & 0o777n), 0o644);

    await writeFile(selfPath, "untrusted inspection copy\n");
    await chmod(selfPath, 0o644);
    const selfTampered = await verifyDeploymentManifest(
      destination,
      result.candidateRootDigest,
    );
    assert.equal(selfTampered.rootDigest, result.candidateRootDigest);

    const coveredPath = absolute(destination, "src/main.mjs");
    await writeFile(coveredPath, "tampered covered bytes\n");
    await chmod(coveredPath, 0o644);
    await assert.rejects(
      verifyDeploymentManifest(destination, result.candidateRootDigest),
      manifestErrorCode("digest_mismatch"),
    );
  });
});

test("selected symlink, hardlink, special entry, and unsafe modes fail before output", async (t) => {
  await t.test("symbolic link", async () => {
    await withSyntheticWorkspace(async ({ workspace, source, destination }) => {
      const selected = absolute(source, "src/main.mjs");
      const outside = path.join(workspace, "outside-main.mjs");
      await writeFile(outside, "outside\n");
      await chmod(outside, 0o644);
      await rm(selected);
      await symlink(outside, selected);

      await assert.rejects(
        packageCodexDeployment(source, destination),
        errorCode("source_symlink"),
      );
      await assertPathMissing(destination);
    });
  });

  await t.test("hard link", async () => {
    await withSyntheticWorkspace(async ({ workspace, source, destination }) => {
      const selected = absolute(source, "src/main.mjs");
      const outside = path.join(workspace, "outside-main.mjs");
      await writeFile(outside, "outside\n");
      await chmod(outside, 0o644);
      await rm(selected);
      await link(outside, selected);

      await assert.rejects(
        packageCodexDeployment(source, destination),
        errorCode("source_hardlink"),
      );
      await assertPathMissing(destination);
    });
  });

  await t.test("special entry", async () => {
    await withSyntheticWorkspace(async ({ source, destination }) => {
      const selected = absolute(source, "src/main.mjs");
      await rm(selected);
      // Filesystem-only synthetic helper. No SDK, Codex CLI, credential,
      // manuscript, or network process is started by this suite.
      await execFileAsync("/usr/bin/mkfifo", [selected]);
      await assert.rejects(
        packageCodexDeployment(source, destination),
        errorCode("source_unsupported_entry"),
      );
      await assertPathMissing(destination);
    });
  });

  await t.test("unsafe permission", async () => {
    await withSyntheticWorkspace(async ({ source, destination }) => {
      await chmod(absolute(source, "src/main.mjs"), 0o666);
      await assert.rejects(
        packageCodexDeployment(source, destination),
        errorCode("source_invalid_mode"),
      );
      await assertPathMissing(destination);
    });
  });

  await t.test("safe but unexpected permission", async () => {
    await withSyntheticWorkspace(async ({ source, destination }) => {
      await chmod(absolute(source, "src/main.mjs"), 0o600);
      await assert.rejects(
        packageCodexDeployment(source, destination),
        errorCode("source_mode_mismatch"),
      );
      await assertPathMissing(destination);
    });
  });
});

test("unknown package descendants and hidden development entries are rejected", async (t) => {
  await t.test("visible package extra", async () => {
    await withSyntheticWorkspace(async ({ source, destination }) => {
      await writeFixtureFile(
        source,
        "node_modules/@openai/codex-sdk/dist/unreviewed.js",
        "extra\n",
      );
      await assert.rejects(
        packageCodexDeployment(source, destination),
        errorCode("source_extra"),
      );
      await assertPathMissing(destination);
    });
  });

  await t.test("hidden package extra", async () => {
    await withSyntheticWorkspace(async ({ source, destination }) => {
      await writeFixtureFile(
        source,
        "node_modules/@openai/codex-sdk/.unreviewed",
        "extra\n",
      );
      await assert.rejects(
        packageCodexDeployment(source, destination),
        errorCode("source_extra"),
      );
      await assertPathMissing(destination);
    });
  });

  await t.test("hidden root extra", async () => {
    await withSyntheticWorkspace(async ({ source, destination }) => {
      await writeFixtureFile(source, ".env", "must not be silently ignored\n");
      await assert.rejects(
        packageCodexDeployment(source, destination),
        errorCode("source_extra"),
      );
      await assertPathMissing(destination);
    });
  });
});

test("pinned SDK, CLI, platform, lock SRI, and installed metadata must match", async (t) => {
  await t.test("root dependency drift", async () => {
    await withSyntheticWorkspace(async ({ source, destination }) => {
      await writeFixtureFile(
        source,
        "package.json",
        jsonBytes({
          name: "fuminiwa-codex-sidecar",
          dependencies: { "@openai/codex-sdk": "0.148.0" },
        }),
      );
      await assert.rejects(
        packageCodexDeployment(source, destination),
        errorCode("source_identity_mismatch"),
      );
      await assertPathMissing(destination);
    });
  });

  await t.test("lock SRI drift", async () => {
    await withSyntheticWorkspace(async ({ source, destination }) => {
      const lockPath = absolute(source, "package-lock.json");
      const lock = JSON.parse(await readFile(lockPath, "utf8"));
      lock.packages["node_modules/@openai/codex-sdk"].integrity =
        "sha512-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==";
      await writeFixtureFile(source, "package-lock.json", jsonBytes(lock));
      await assert.rejects(
        packageCodexDeployment(source, destination),
        errorCode("source_identity_mismatch"),
      );
      await assertPathMissing(destination);
    });
  });

  await t.test("installed platform metadata drift", async () => {
    await withSyntheticWorkspace(async ({ source, destination }) => {
      const packagePath =
        "node_modules/@openai/codex-darwin-arm64/package.json";
      await writeFixtureFile(
        source,
        packagePath,
        jsonBytes({
          name: "@openai/codex",
          version: "0.147.0-darwin-arm64",
          os: ["darwin"],
          cpu: ["x64"],
        }),
      );
      await assert.rejects(
        packageCodexDeployment(source, destination),
        errorCode("source_identity_mismatch"),
      );
      await assertPathMissing(destination);
    });
  });
});

test("an existing destination is never modified or removed", async () => {
  await withSyntheticWorkspace(async ({ source, destination }) => {
    await mkdir(destination, { mode: 0o700 });
    await chmod(destination, 0o700);
    const sentinel = path.join(destination, ".keep");
    await writeFile(sentinel, "existing bytes\n");
    await chmod(sentinel, 0o600);

    await assert.rejects(
      packageCodexDeployment(source, destination),
      errorCode("destination_exists"),
    );
    assert.equal(await readFile(sentinel, "utf8"), "existing bytes\n");
  });
});

test("noncanonical destination spelling fails before creating output", async () => {
  await withSyntheticWorkspace(async ({ source, destination }) => {
    await assert.rejects(
      packageCodexDeployment(source, `${destination}/`),
      errorCode("invalid_destination_root"),
    );
    await assertPathMissing(destination);
  });
});

test("an injected destination extra fails and retains an unusable partial root", async () => {
  await withSyntheticWorkspace(
    async ({ source, destination }) => {
      const packaging = observePromise(
        packageCodexDeployment(source, destination),
      );
      await waitForPath(destination);
      const injected = path.join(destination, ".injected");
      await writeFile(injected, "not allowlisted\n");
      await chmod(injected, 0o600);

      const outcome = await packaging;
      assert.equal(
        retainedPartialError("destination_extra")(outcome.error),
        true,
      );
      assert.equal(await readFile(injected, "utf8"), "not allowlisted\n");
      await assert.rejects(
        packageCodexDeployment(source, destination),
        errorCode("destination_exists"),
      );
    },
    { largeFirstFile: true },
  );
});

test("a replacement root is retained and never recursively removed", async () => {
  await withSyntheticWorkspace(
    async ({ workspace, source, destination }) => {
      const packaging = observePromise(
        packageCodexDeployment(source, destination),
      );
      const finalDirectory = CODEX_DEPLOYMENT_DIRECTORY_ALLOWLIST_V1.at(-1);
      await waitForPath(absolute(destination, finalDirectory.relativePath));

      const displaced = path.join(workspace, "displaced-owned-root");
      await rename(destination, displaced);
      await mkdir(destination, { mode: 0o700 });
      await chmod(destination, 0o700);
      for (const spec of CODEX_DEPLOYMENT_DIRECTORY_ALLOWLIST_V1) {
        await mkdir(absolute(destination, spec.relativePath), { mode: spec.mode });
        await chmod(absolute(destination, spec.relativePath), spec.mode);
      }
      const sentinel = path.join(destination, ".keep");
      await writeFile(sentinel, "replacement bytes\n");
      await chmod(sentinel, 0o600);

      const outcome = await packaging;
      assert.equal(
        retainedPartialError([
          "destination_identity_changed",
          "copy_failed",
        ])(outcome.error),
        true,
      );
      assert.equal(await readFile(sentinel, "utf8"), "replacement bytes\n");
      assert.equal((await lstat(displaced)).isDirectory(), true);
    },
    { largeFirstFile: true },
  );
});

test("packager source has no static or dynamic provider and launcher imports", async () => {
  const source = await readFile(
    path.join(testDirectory, "../src/deployment-packager.mjs"),
    "utf8",
  );
  assert.doesNotMatch(source, /\bfrom\s+["']@openai\//u);
  assert.doesNotMatch(source, /\bimport\s*\(/u);
  assert.doesNotMatch(source, /\brequire\s*\(/u);
  assert.doesNotMatch(source, /\bcreateRequire\b/u);
  assert.doesNotMatch(source, /["'](?:node:)?child_process["']/u);
  assert.equal(source.includes("src/codex-sdk-capture.mjs"), false);
});
