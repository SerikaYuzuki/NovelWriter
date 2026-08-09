import assert from "node:assert/strict";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  PINNED_CODEX_CLI_INTEGRITY,
  PINNED_CODEX_CLI_VERSION,
  PINNED_CODEX_SDK_INTEGRITY,
  PINNED_CODEX_SDK_VERSION,
  PROTOCOL_GOLDEN_APPLICATION_PROMPT,
  PROTOCOL_GOLDEN_MODEL_ID,
  PROTOCOL_GOLDEN_OUTPUT_SCHEMA,
  PROTOCOL_GOLDEN_OUTPUT_SCHEMA_TEXT,
  SYNTHETIC_STRUCTURED_OUTPUT,
  SYNTHETIC_UNICODE_PROMPT,
  captureCancellation,
  captureSDKFailure,
  captureStubbornCancellation,
  captureSuccessfulSDKInvocation,
  captureUnicodeOutputSDKInvocation,
  captureUnicodeInputSDKInvocation,
  readPinnedPackageIdentity,
} from "../src/codex-sdk-capture.mjs";

test("Codex SDK and CLI package identities are exact-pinned", async () => {
  const identity = await readPinnedPackageIdentity();

  assert.equal(identity.requestedSDKVersion, PINNED_CODEX_SDK_VERSION);
  assert.equal(identity.lockedSDK.version, PINNED_CODEX_SDK_VERSION);
  assert.equal(identity.lockedSDK.integrity, PINNED_CODEX_SDK_INTEGRITY);
  assert.equal(identity.lockedCLI.version, PINNED_CODEX_CLI_VERSION);
  assert.equal(identity.lockedCLI.integrity, PINNED_CODEX_CLI_INTEGRITY);
  assert.equal(identity.installedSDKVersion, PINNED_CODEX_SDK_VERSION);
  assert.equal(identity.installedCLIVersion, PINNED_CODEX_CLI_VERSION);
});

test("SDK capture is anchored to the protocol-v1 golden prompt and schema", async () => {
  const result = await captureSuccessfulSDKInvocation();
  const schemaPath = result.capture.output_schema_path;

  assert.deepEqual(result.capture.argv, [
    "exec",
    "--experimental-json",
    "--model",
    PROTOCOL_GOLDEN_MODEL_ID,
    "--sandbox",
    "read-only",
    "--cd",
    result.expectedPaths.workingDirectory,
    "--skip-git-repo-check",
    "--output-schema",
    schemaPath,
    "--config",
    "sandbox_workspace_write.network_access=false",
    "--config",
    'web_search="disabled"',
    "--config",
    'approval_policy="never"',
  ]);
  assert.equal(result.capture.executable_path, result.expectedPaths.fakeCLIPath);
  assert.deepEqual(result.capture.runtime, {
    architecture: process.arch,
    node_path: process.execPath,
    node_version: process.version,
  });
  assert.equal(result.capture.stdin_text, PROTOCOL_GOLDEN_APPLICATION_PROMPT);
  assert.equal(
    result.capture.stdin_utf8_base64,
    Buffer.from(PROTOCOL_GOLDEN_APPLICATION_PROMPT, "utf8").toString("base64"),
  );
  assert.equal(
    result.capture.stdin_utf8_byte_count,
    Buffer.byteLength(PROTOCOL_GOLDEN_APPLICATION_PROMPT, "utf8"),
  );
  assert.equal(result.capture.output_schema_text, PROTOCOL_GOLDEN_OUTPUT_SCHEMA_TEXT);
  assert.equal(
    result.capture.output_schema_utf8_base64,
    Buffer.from(PROTOCOL_GOLDEN_OUTPUT_SCHEMA_TEXT, "utf8").toString("base64"),
  );
  assert.deepEqual(JSON.parse(result.capture.output_schema_text), PROTOCOL_GOLDEN_OUTPUT_SCHEMA);
  assert.equal(result.outputSchemaFileExistsAfterRun, false);
  assert.equal(result.outputSchemaDirectoryExistsAfterRun, false);
  assert.equal(path.dirname(path.dirname(schemaPath)), os.tmpdir());
  assert.equal(schemaPath.startsWith(`${result.expectedPaths.requestTemporaryDirectory}${path.sep}`), false);

  const expectedSDKEnvironment = {
    ...result.environment,
    CODEX_INTERNAL_ORIGINATOR_OVERRIDE: "codex_sdk_ts",
  };
  for (const [key, value] of Object.entries(expectedSDKEnvironment)) {
    assert.equal(result.capture.env[key], value);
  }
  const platformInjectedEnvironmentKeys = Object.keys(result.capture.env).filter(
    (key) => !Object.hasOwn(expectedSDKEnvironment, key),
  );
  if (process.platform === "darwin") {
    assert.deepEqual(platformInjectedEnvironmentKeys, ["__CF_USER_TEXT_ENCODING"]);
    assert.match(
      result.capture.env.__CF_USER_TEXT_ENCODING,
      /^0x[0-9A-Fa-f]+:0x[0-9A-Fa-f]+:0x[0-9A-Fa-f]+$/u,
    );
  } else {
    assert.deepEqual(platformInjectedEnvironmentKeys, []);
  }
  assert.equal(Object.hasOwn(result.capture.env, "CODEX_API_KEY"), false);
  assert.equal(Object.hasOwn(result.capture.env, "HOME"), false);
  assert.equal(Object.hasOwn(result.capture.env, "PATH"), false);

  assert.equal(result.threadID, "synthetic-thread");
  assert.equal(result.turn.finalResponse, SYNTHETIC_STRUCTURED_OUTPUT);
  assert.deepEqual(JSON.parse(result.turn.finalResponse), {
    replacement: "出来る。",
    summary: "重複した句点を整理しました。",
    warnings: [],
  });
  assert.deepEqual(result.turn.usage, {
    input_tokens: 7,
    cached_input_tokens: 0,
    cache_write_input_tokens: 0,
    output_tokens: 5,
    reasoning_output_tokens: 0,
  });
});

test("SDK writes literal U+2028/U+2029 input to fake CLI stdin unchanged", async () => {
  const result = await captureUnicodeInputSDKInvocation();

  assert.equal(result.capture.stdin_text, SYNTHETIC_UNICODE_PROMPT);
  assert.equal(
    result.capture.stdin_utf8_base64,
    Buffer.from(SYNTHETIC_UNICODE_PROMPT, "utf8").toString("base64"),
  );
  assert.equal(
    result.capture.stdin_utf8_byte_count,
    Buffer.byteLength(SYNTHETIC_UNICODE_PROMPT, "utf8"),
  );
  assert.equal(result.turn.finalResponse, SYNTHETIC_STRUCTURED_OUTPUT);
});

test("AbortSignal reaches the direct fake CLI as SIGTERM", async () => {
  const result = await captureCancellation();

  assert.equal(result.firstEvent.done, false);
  assert.deepEqual(result.firstEvent.value, {
    type: "thread.started",
    thread_id: "synthetic-thread",
  });
  assert.deepEqual(result.failure, {
    code: "ABORT_ERR",
    message: "The operation was aborted",
    name: "AbortError",
  });
  assert.equal(result.capture.phase, "signal_received");
  assert.equal(result.capture.received_signal, "SIGTERM");
  assert.equal(result.capture.stdin_text, PROTOCOL_GOLDEN_APPLICATION_PROMPT);
  assert.equal(result.outputSchemaFileExistsAfterRun, false);
  assert.equal(result.outputSchemaDirectoryExistsAfterRun, false);
});

test(
  "SDK cancellation does not terminate a direct fake CLI that ignores SIGTERM",
  { skip: process.platform === "win32", timeout: 10_000 },
  async () => {
    const result = await captureStubbornCancellation();

    assert.equal(result.firstEvent.done, false);
    assert.deepEqual(result.firstEvent.value, {
      type: "thread.started",
      thread_id: "synthetic-thread",
    });
    assert.equal(result.capture.pid, result.capturedPID);
    assert.equal(result.capture.phase, "sigterm_ignored");
    assert.equal(result.capture.received_signal, "SIGTERM");
    assert.equal(result.capture.sigterm_count, 1);
    assert.equal(result.drainSettledBeforeForcedKill, false);
    assert.equal(result.processAliveAfterAbort, true);
    assert.equal(result.forcedKillSent, true);
    assert.equal(result.processAliveAfterCleanup, false);
    assert.deepEqual(result.failure, {
      code: "ABORT_ERR",
      message: "The operation was aborted",
      name: "AbortError",
    });
    assert.equal(result.outputSchemaFileExistsAfterRun, false);
    assert.equal(result.outputSchemaDirectoryExistsAfterRun, false);
    assert.throws(
      () => process.kill(result.capturedPID, 0),
      (error) => error?.code === "ESRCH",
    );
  },
);

test("nonzero CLI exit exposes raw stderr in the SDK error", async () => {
  const result = await captureSDKFailure("stderr_exit");

  assert.equal(result.failure.name, "Error");
  assert.equal(result.failure.code, null);
  assert.match(result.failure.message, /exited with code 23/u);
  assert.match(result.failure.message, /SYNTHETIC_RAW_STDERR_SENTINEL/u);
});

test("turn.failed exposes the CLI-provided raw error message", async () => {
  const result = await captureSDKFailure("turn_failure");

  assert.deepEqual(result.failure, {
    code: null,
    message: "SYNTHETIC_RAW_TURN_FAILURE_SENTINEL",
    name: "Error",
  });
});

test("malformed stdout is copied into the SDK parse error", async () => {
  const result = await captureSDKFailure("malformed_stdout");

  assert.equal(result.failure.name, "Error");
  assert.equal(result.failure.code, null);
  assert.match(result.failure.message, /Failed to parse item:/u);
  assert.match(result.failure.message, /SYNTHETIC_RAW_STDOUT_SENTINEL/u);
});

test("literal U+2028 output is classified without accepting mutation", async () => {
  const result = await captureUnicodeOutputSDKInvocation("unicode_line_separator");

  assertUnicodeOutputCompatibility(result, "\u2028");
});

test("literal U+2029 output is classified without accepting mutation", async () => {
  const result = await captureUnicodeOutputSDKInvocation("unicode_paragraph_separator");

  assertUnicodeOutputCompatibility(result, "\u2029");
});

function assertUnicodeOutputCompatibility(result, separator) {
  const emittedStdout = Buffer.from(result.capture.stdout_utf8_base64, "base64").toString("utf8");
  const expectedStructuredOutput = JSON.stringify({
    replacement: `合成出力A${separator}合成出力B`,
    summary: "合成separator probe",
    warnings: [],
  });

  assert.deepEqual(result.nodeIdentity, {
    architecture: process.arch,
    executablePath: process.execPath,
    version: process.version,
  });
  assert.equal(emittedStdout, result.capture.stdout_text);
  assert.ok(emittedStdout.includes(separator));
  assert.doesNotThrow(() => JSON.parse(emittedStdout.split("\n")[2]));
  assert.equal(result.outputSchemaFileExistsAfterRun, false);
  assert.equal(result.outputSchemaDirectoryExistsAfterRun, false);

  if (result.outcome === "completed") {
    assert.equal(result.failure, null);
    assert.equal(result.turn.finalResponse, expectedStructuredOutput);
    assert.equal(JSON.parse(result.turn.finalResponse).replacement, `合成出力A${separator}合成出力B`);
  } else {
    assert.equal(result.outcome, "failed");
    assert.equal(result.turn, null);
    assert.equal(result.failure.name, "Error");
    assert.match(result.failure.message, /Failed to parse item:/u);
  }

  const expectedKnownOutcome = new Map([
    ["v22.23.1", "completed"],
    ["v26.4.0", "failed"],
  ]).get(process.version);
  if (expectedKnownOutcome !== undefined) {
    assert.equal(result.outcome, expectedKnownOutcome);
  }
}
