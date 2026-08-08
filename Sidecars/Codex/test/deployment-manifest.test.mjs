import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
  chmod,
  link,
  mkdir,
  mkdtemp,
  open,
  readFile,
  realpath,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

import {
  DEPLOYMENT_MANIFEST_SELF_PATH,
  DeploymentManifestError,
  MAXIMUM_CANONICAL_MANIFEST_BYTES,
  MAXIMUM_DEPLOYMENT_FILE_BYTES,
  createDeploymentManifest,
  decodeCanonicalDeploymentRelativePath,
  verifyDeclaredLoadedFiles,
  verifyDeploymentManifest,
} from "../src/deployment-manifest.mjs";

async function withTemporaryRoot(run) {
  const temporary = await mkdtemp(path.join(tmpdir(), "fuminiwa-manifest-v1-"));
  const root = await realpath(temporary);
  await chmod(root, 0o700);
  try {
    return await run(root);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}

async function writeDeploymentFile(root, relativePath, contents, mode = 0o644) {
  const absolute = path.join(root, relativePath);
  const parentComponents = path.dirname(relativePath).split(path.sep);
  let parent = root;
  for (const component of parentComponents) {
    if (component === ".") {
      continue;
    }
    parent = path.join(parent, component);
    await mkdir(parent, { recursive: true, mode: 0o755 });
    await chmod(parent, 0o755);
  }
  await writeFile(absolute, contents);
  await chmod(absolute, mode);
  return absolute;
}

function errorCode(code) {
  return (error) => error instanceof DeploymentManifestError && error.code === code;
}

function decodeCanonicalRecordBoundaries(bytes) {
  const magic = Buffer.from("FUMINIWA-CODEX-DEPLOYMENT-MANIFEST\0", "ascii");
  assert.equal(bytes.subarray(0, magic.length).equals(magic), true);
  let offset = magic.length;
  assert.equal(bytes.readUInt32BE(offset), 1);
  offset += 4;
  const count = Number(bytes.readBigUInt64BE(offset));
  offset += 8;
  const boundaries = [];
  for (let index = 0; index < count; index += 1) {
    const recordLength = Number(bytes.readBigUInt64BE(offset));
    offset += 8;
    boundaries.push([offset, offset + recordLength]);
    offset += recordLength;
  }
  assert.equal(offset, bytes.length);
  return boundaries;
}

test("canonical manifest covers root, directories, and regular files", async () => {
  await withTemporaryRoot(async (root) => {
    await mkdir(path.join(root, "lib"), { mode: 0o755 });
    await chmod(path.join(root, "lib"), 0o755);
    await writeDeploymentFile(root, "z-last.txt", "z", 0o600);
    await writeDeploymentFile(root, "lib/main.mjs", "export default 1;\n", 0o644);
    await writeDeploymentFile(root, "a-first.txt", "alpha", 0o644);

    const manifest = await createDeploymentManifest(root);
    assert.equal(manifest.version, 1);
    assert.equal(
      manifest.rootDigest,
      "15b98ccfac850c24e2427249c55c9fba5aba29b6ef1632301136688c13d35288",
    );
    assert.equal(manifest.canonicalBytes.length, 278);
    assert.deepEqual(
      manifest.records.map((record) => record.path),
      ["", "a-first.txt", "lib", "lib/main.mjs", "z-last.txt"],
    );
    assert.deepEqual(
      manifest.records.map((record) => record.kind),
      ["directory", "file", "directory", "file", "file"],
    );
    assert.equal(manifest.records[0].mode, 0o700);
    assert.equal(manifest.records[1].size, 5);
    assert.equal(
      manifest.records[1].sha256,
      createHash("sha256").update("alpha").digest("hex"),
    );
    assert.equal(decodeCanonicalRecordBoundaries(manifest.canonicalBytes).length, 5);

    const repeated = await createDeploymentManifest(root);
    assert.equal(repeated.rootDigest, manifest.rootDigest);
    assert.equal(repeated.canonicalBytes.equals(manifest.canonicalBytes), true);
  });
});

test("UTF-8 byte ordering is independent of creation and enumeration order", async () => {
  const populate = async (root, names) => {
    for (const name of names) {
      await writeDeploymentFile(root, name, `content:${name}`, 0o644);
    }
  };

  let firstDigest;
  await withTemporaryRoot(async (root) => {
    await populate(root, ["z.txt", "ä.txt", "a.txt"]);
    firstDigest = (await createDeploymentManifest(root)).rootDigest;
  });
  await withTemporaryRoot(async (root) => {
    await populate(root, ["a.txt", "ä.txt", "z.txt"]);
    const manifest = await createDeploymentManifest(root);
    assert.deepEqual(
      manifest.records.map((record) => record.path),
      ["", "a.txt", "z.txt", "ä.txt"],
    );
    assert.equal(manifest.rootDigest, firstDigest);
  });
});

test("file content tampering changes the root digest and verification fails closed", async () => {
  await withTemporaryRoot(async (root) => {
    const file = await writeDeploymentFile(root, "main.mjs", "export const value = 1;\n");
    const expected = (await createDeploymentManifest(root)).rootDigest;

    await writeFile(file, "export const value = 2;\n");
    await chmod(file, 0o644);

    await assert.rejects(
      verifyDeploymentManifest(root, expected),
      errorCode("digest_mismatch"),
    );
  });
});

test("the fixed self manifest file is the only excluded descendant", async () => {
  await withTemporaryRoot(async (root) => {
    await writeDeploymentFile(root, "main.mjs", "export {};\n");
    const withoutSelf = await createDeploymentManifest(root);

    await writeDeploymentFile(root, DEPLOYMENT_MANIFEST_SELF_PATH, "generated bytes", 0o644);
    const withSelf = await createDeploymentManifest(root);
    assert.equal(withSelf.rootDigest, withoutSelf.rootDigest);
    assert.equal(
      withSelf.records.some((record) => record.path === DEPLOYMENT_MANIFEST_SELF_PATH),
      false,
    );

    await writeDeploymentFile(root, `nested/${DEPLOYMENT_MANIFEST_SELF_PATH}`, "covered", 0o644);
    const nestedSelfName = await createDeploymentManifest(root);
    assert.notEqual(nestedSelfName.rootDigest, withoutSelf.rootDigest);
    assert.equal(
      nestedSelfName.records.some(
        (record) => record.path === `nested/${DEPLOYMENT_MANIFEST_SELF_PATH}`,
      ),
      true,
    );
  });
});

test("symbolic links are rejected, including links that stay inside the root", async () => {
  await withTemporaryRoot(async (root) => {
    await writeDeploymentFile(root, "target.mjs", "export {};\n");
    await symlink("target.mjs", path.join(root, "alias.mjs"));

    await assert.rejects(createDeploymentManifest(root), errorCode("symlink"));
  });
});

test("hard-linked files are rejected even when the other link is outside", async () => {
  await withTemporaryRoot(async (root) => {
    const original = await writeDeploymentFile(root, "original.mjs", "export {};\n");
    const outside = `${root}-outside-hardlink`;
    try {
      await link(original, outside);
      await assert.rejects(createDeploymentManifest(root), errorCode("hardlink"));
    } finally {
      await rm(outside, { force: true });
    }
  });
});

test("relative paths reject invalid UTF-8, empty components, and oversized components", () => {
  assert.throws(
    () => decodeCanonicalDeploymentRelativePath(Buffer.from([0x69, 0x6e, 0xff])),
    errorCode("invalid_path"),
  );
  for (const value of ["", "/a", "a/", "a//b", ".", "../a"]) {
    assert.throws(
      () => decodeCanonicalDeploymentRelativePath(Buffer.from(value, "utf8")),
      errorCode("invalid_path"),
    );
  }
  assert.throws(
    () => decodeCanonicalDeploymentRelativePath(Buffer.alloc(256, 0x61)),
    errorCode("invalid_path"),
  );
  assert.equal(
    decodeCanonicalDeploymentRelativePath(Buffer.from("lib/日本語.mjs", "utf8")),
    "lib/日本語.mjs",
  );
});

test("permission mode is canonical input and unsafe mode bits are rejected", async () => {
  await withTemporaryRoot(async (root) => {
    const file = await writeDeploymentFile(root, "main.mjs", "export {};\n", 0o644);
    const first = await createDeploymentManifest(root);

    await chmod(file, 0o600);
    const second = await createDeploymentManifest(root);
    assert.notEqual(second.rootDigest, first.rootDigest);
    assert.equal(second.records.find((record) => record.path === "main.mjs").mode, 0o600);

    await chmod(file, 0o666);
    await assert.rejects(createDeploymentManifest(root), errorCode("invalid_mode"));
  });
});

test("a sparse file over the fixed per-file limit is rejected before hashing", async () => {
  await withTemporaryRoot(async (root) => {
    const oversized = path.join(root, "oversized.bin");
    const handle = await open(oversized, "w", 0o600);
    try {
      await handle.truncate(MAXIMUM_DEPLOYMENT_FILE_BYTES + 1);
    } finally {
      await handle.close();
    }

    await assert.rejects(createDeploymentManifest(root), errorCode("resource_limit"));
  });
});

test("the excluded self manifest still has a fixed size limit", async () => {
  await withTemporaryRoot(async (root) => {
    const selfManifest = path.join(root, DEPLOYMENT_MANIFEST_SELF_PATH);
    const handle = await open(selfManifest, "w", 0o600);
    try {
      await handle.truncate(MAXIMUM_CANONICAL_MANIFEST_BYTES + 1);
    } finally {
      await handle.close();
    }

    await assert.rejects(createDeploymentManifest(root), errorCode("resource_limit"));
  });
});

test("root and self-exclusion paths cannot hide symlinks or directories", async () => {
  await withTemporaryRoot(async (root) => {
    await mkdir(path.join(root, DEPLOYMENT_MANIFEST_SELF_PATH), { mode: 0o755 });
    await assert.rejects(createDeploymentManifest(root), errorCode("unsupported_entry"));
  });

  await withTemporaryRoot(async (root) => {
    const alias = `${root}-alias`;
    try {
      await symlink(root, alias);
      await assert.rejects(createDeploymentManifest(alias), errorCode("invalid_root"));
    } finally {
      await rm(alias, { force: true });
    }
  });
});

test("declared loaded files must be canonical files contained in the verified tree", async () => {
  await withTemporaryRoot(async (root) => {
    const inside = await writeDeploymentFile(root, "src/main.mjs", "export {};\n");
    const expected = (await createDeploymentManifest(root)).rootDigest;
    const verified = await verifyDeclaredLoadedFiles(root, expected, [inside]);
    assert.equal(verified.rootDigest, expected);

    const outside = `${root}-outside-module.mjs`;
    try {
      await writeFile(outside, "export {};\n");
      await chmod(outside, 0o644);
      await assert.rejects(
        verifyDeclaredLoadedFiles(root, expected, [outside]),
        errorCode("containment"),
      );
    } finally {
      await rm(outside, { force: true });
    }
  });
});

test("verification rejects noncanonical expected digest spellings", async () => {
  await withTemporaryRoot(async (root) => {
    await writeDeploymentFile(root, "main.mjs", "export {};\n");
    const digest = (await createDeploymentManifest(root)).rootDigest;
    await assert.rejects(
      verifyDeploymentManifest(root, digest.toUpperCase()),
      errorCode("invalid_digest"),
    );
  });
});

test("the deployment file digest matches the bytes read from disk", async () => {
  await withTemporaryRoot(async (root) => {
    const file = await writeDeploymentFile(root, "payload.bin", Buffer.from([0, 1, 2, 255]));
    const manifest = await createDeploymentManifest(root);
    const record = manifest.records.find((candidate) => candidate.path === "payload.bin");
    const bytes = await readFile(file);
    assert.equal(record.sha256, createHash("sha256").update(bytes).digest("hex"));
  });
});
