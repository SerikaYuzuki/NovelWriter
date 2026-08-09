import { Codex } from "@openai/codex-sdk";
import { promises as fs, readFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const SIDECAR_ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const PROTOCOL_GOLDEN_START = JSON.parse(
  readFileSync(path.join(SIDECAR_ROOT, "fixtures", "protocol-v1", "start.jsonl"), "utf8"),
);

export const PINNED_CODEX_SDK_VERSION = "0.147.0";
export const PINNED_CODEX_SDK_INTEGRITY =
  "sha512-nJL0maDBZy31uEArs+u46tW22veNdHjfs96AGaFTnI3jF+g8U+a422uaPiDZwEKmyxcNwStTRz6sIh6C7XxGFQ==";
export const PINNED_CODEX_CLI_VERSION = "0.147.0";
export const PINNED_CODEX_CLI_INTEGRITY =
  "sha512-EQLEXecAG2ptxI7UpBMo2TR/ga5596/c/OsYF/0LoUDh5JANZ7IoGqlzBEWbuEVQ76JePIbtTW/ihCkp1a7Z3w==";

export const PROTOCOL_GOLDEN_MODEL_ID = PROTOCOL_GOLDEN_START.model_id;
export const PROTOCOL_GOLDEN_APPLICATION_PROMPT = PROTOCOL_GOLDEN_START.application_prompt;
export const PROTOCOL_GOLDEN_OUTPUT_SCHEMA_TEXT =
  PROTOCOL_GOLDEN_START.application_response_schema;
export const PROTOCOL_GOLDEN_OUTPUT_SCHEMA = Object.freeze(
  JSON.parse(PROTOCOL_GOLDEN_OUTPUT_SCHEMA_TEXT),
);
export const SYNTHETIC_UNICODE_PROMPT = "合成入力A\u2028合成入力B\u2029合成入力C";
export const SYNTHETIC_STRUCTURED_OUTPUT = JSON.stringify({
  replacement: "出来る。",
  summary: "重複した句点を整理しました。",
  warnings: [],
});
const FAILURE_BEHAVIORS = new Set([
  "stderr_exit",
  "turn_failure",
  "malformed_stdout",
]);
const UNICODE_OUTPUT_BEHAVIORS = new Set([
  "unicode_line_separator",
  "unicode_paragraph_separator",
]);
const CANCELLATION_STEP_TIMEOUT_MILLISECONDS = 3_000;
const PROCESS_EXIT_TIMEOUT_MILLISECONDS = 2_000;
const PROCESS_POLL_INTERVAL_MILLISECONDS = 10;
const STUBBORN_OBSERVATION_MILLISECONDS = 150;

const FAKE_CLI_SOURCE = String.raw`
import fs from "node:fs";

const capturePath = process.env.FUMINIWA_CAPTURE_PATH;
const behavior = process.env.FUMINIWA_FAKE_BEHAVIOR;
if (!capturePath || !behavior) {
  process.exit(97);
}

const inputChunks = [];
for await (const chunk of process.stdin) {
  inputChunks.push(chunk);
}
const input = Buffer.concat(inputChunks);
const argv = process.argv.slice(2);
const outputSchemaFlagIndex = argv.indexOf("--output-schema");
const outputSchemaPath =
  outputSchemaFlagIndex === -1 ? null : argv[outputSchemaFlagIndex + 1] ?? null;
const outputSchema =
  outputSchemaPath === null ? null : fs.readFileSync(outputSchemaPath);
const capturedEnvironment = Object.fromEntries(
  Object.entries(process.env).sort(([left], [right]) => left.localeCompare(right)),
);

const baseCapture = {
  argv,
  env: capturedEnvironment,
  executable_path: process.argv[1],
  pid: process.pid,
  runtime: {
    architecture: process.arch,
    node_path: process.execPath,
    node_version: process.version,
  },
  stdin_text: input.toString("utf8"),
  stdin_utf8_base64: input.toString("base64"),
  stdin_utf8_byte_count: input.byteLength,
  output_schema_path: outputSchemaPath,
  output_schema_text: outputSchema?.toString("utf8") ?? null,
  output_schema_utf8_base64: outputSchema?.toString("base64") ?? null,
};

let captureState = baseCapture;
function persist(extra) {
  captureState = { ...captureState, ...extra };
  fs.writeFileSync(capturePath, JSON.stringify(captureState), "utf8");
}

function emitRecords(records) {
  const stdout = records.map((record) => JSON.stringify(record)).join("\n") + "\n";
  persist({
    phase: "stdout_emitted",
    stdout_text: stdout,
    stdout_utf8_base64: Buffer.from(stdout, "utf8").toString("base64"),
  });
  process.stdout.write(stdout);
}

let sigtermCount = 0;
process.on("SIGTERM", () => {
  sigtermCount += 1;
  persist({
    phase: behavior === "stubborn_cancel" ? "sigterm_ignored" : "signal_received",
    received_signal: "SIGTERM",
    sigterm_count: sigtermCount,
  });
  if (behavior !== "stubborn_cancel") {
    process.exit(143);
  }
});

persist({ phase: "stdin_captured", received_signal: null, sigterm_count: 0 });

const threadStarted = {
  type: "thread.started",
  thread_id: "synthetic-thread",
};
const turnStarted = { type: "turn.started" };

if (behavior === "success") {
  const structuredOutput = JSON.stringify({
    replacement: "出来る。",
    summary: "重複した句点を整理しました。",
    warnings: [],
  });
  const records = [
    threadStarted,
    turnStarted,
    {
      type: "item.completed",
      item: {
        id: "synthetic-agent-message",
        type: "agent_message",
        text: structuredOutput,
      },
    },
    {
      type: "turn.completed",
      usage: {
        input_tokens: 7,
        cached_input_tokens: 0,
        cache_write_input_tokens: 0,
        output_tokens: 5,
        reasoning_output_tokens: 0,
      },
    },
  ];
  emitRecords(records);
} else if (behavior === "cancel" || behavior === "stubborn_cancel") {
  emitRecords([threadStarted]);
  setInterval(() => {}, 1_000);
} else if (behavior === "stderr_exit") {
  persist({ phase: "stderr_exit" });
  process.stderr.write("SYNTHETIC_RAW_STDERR_SENTINEL\n");
  process.exitCode = 23;
} else if (behavior === "turn_failure") {
  const records = [
    threadStarted,
    turnStarted,
    {
      type: "turn.failed",
      error: { message: "SYNTHETIC_RAW_TURN_FAILURE_SENTINEL" },
    },
  ];
  emitRecords(records);
} else if (behavior === "malformed_stdout") {
  const stdout = "SYNTHETIC_RAW_STDOUT_SENTINEL not-json\n";
  persist({
    phase: "stdout_emitted",
    stdout_text: stdout,
    stdout_utf8_base64: Buffer.from(stdout, "utf8").toString("base64"),
  });
  process.stdout.write(stdout);
} else if (
  behavior === "unicode_line_separator" ||
  behavior === "unicode_paragraph_separator"
) {
  const separator = behavior === "unicode_line_separator" ? "\u2028" : "\u2029";
  const structuredOutput = JSON.stringify({
    replacement: "合成出力A" + separator + "合成出力B",
    summary: "合成separator probe",
    warnings: [],
  });
  emitRecords([
    threadStarted,
    turnStarted,
    {
      type: "item.completed",
      item: {
        id: "synthetic-agent-message",
        type: "agent_message",
        text: structuredOutput,
      },
    },
    {
      type: "turn.completed",
      usage: {
        input_tokens: 7,
        cached_input_tokens: 0,
        cache_write_input_tokens: 0,
        output_tokens: 5,
        reasoning_output_tokens: 0,
      },
    },
  ]);
} else {
  process.exitCode = 98;
}
`;

export async function readPinnedPackageIdentity() {
  const packageJSON = JSON.parse(await fs.readFile(path.join(SIDECAR_ROOT, "package.json"), "utf8"));
  const packageLock = JSON.parse(
    await fs.readFile(path.join(SIDECAR_ROOT, "package-lock.json"), "utf8"),
  );
  const installedSDK = JSON.parse(
    await fs.readFile(
      path.join(SIDECAR_ROOT, "node_modules", "@openai", "codex-sdk", "package.json"),
      "utf8",
    ),
  );
  const installedCLI = JSON.parse(
    await fs.readFile(
      path.join(SIDECAR_ROOT, "node_modules", "@openai", "codex", "package.json"),
      "utf8",
    ),
  );

  return {
    requestedSDKVersion: packageJSON.dependencies?.["@openai/codex-sdk"],
    lockedSDK: packageLock.packages?.["node_modules/@openai/codex-sdk"],
    lockedCLI: packageLock.packages?.["node_modules/@openai/codex"],
    installedSDKVersion: installedSDK.version,
    installedCLIVersion: installedCLI.version,
  };
}

export async function captureSuccessfulSDKInvocation() {
  return captureSuccessfulInvocation(PROTOCOL_GOLDEN_APPLICATION_PROMPT);
}

export async function captureUnicodeInputSDKInvocation() {
  return captureSuccessfulInvocation(SYNTHETIC_UNICODE_PROMPT);
}

async function captureSuccessfulInvocation(prompt) {
  return withCaptureWorkspace("success", async (context) => {
    const { thread, environment } = createSyntheticThread(context);
    const turn = await thread.run(prompt, {
      outputSchema: PROTOCOL_GOLDEN_OUTPUT_SCHEMA,
    });
    const capture = await readCapture(context.capturePath);
    const schemaArtifacts = await schemaArtifactStatus(capture);

    return {
      capture,
      environment,
      expectedPaths: publicPaths(context),
      ...schemaArtifacts,
      threadID: thread.id,
      turn,
    };
  });
}

export async function captureCancellation() {
  return withCaptureWorkspace("cancel", async (context) => {
    const { thread, environment } = createSyntheticThread(context);
    const abortController = new AbortController();
    let capturedPID = null;
    let drainPromise = null;
    let iterator = null;

    try {
      const streamed = await withWallClockDeadline(
        thread.runStreamed(PROTOCOL_GOLDEN_APPLICATION_PROMPT, {
          outputSchema: PROTOCOL_GOLDEN_OUTPUT_SCHEMA,
          signal: abortController.signal,
        }),
        "Codex SDK cancellation stream creation",
      );
      iterator = streamed.events[Symbol.asyncIterator]();
      const firstEvent = await withWallClockDeadline(
        iterator.next(),
        "Codex SDK cancellation first event",
      );
      const startedCapture = await waitForCapture(
        context.capturePath,
        (capture) => Number.isInteger(capture.pid),
        "Codex SDK cancellation child PID",
      );
      capturedPID = validateCapturedPID(startedCapture, context);

      abortController.abort();
      drainPromise = captureIteratorFailure(iterator);
      const failure = await withWallClockDeadline(
        drainPromise,
        "Codex SDK cancellation drain",
      );
      const capture = await waitForCapture(
        context.capturePath,
        (candidate) => candidate.phase === "signal_received",
        "Codex SDK cancellation signal capture",
      );
      const schemaArtifacts = await schemaArtifactStatus(capture);

      return {
        capture,
        environment,
        expectedPaths: publicPaths(context),
        ...schemaArtifacts,
        failure,
        firstEvent,
      };
    } finally {
      if (!abortController.signal.aborted) {
        abortController.abort();
      }
      await ensureCancellationProbeCleanup({
        capturePath: context.capturePath,
        capturedPID,
        context,
        drainPromise,
        iterator,
      });
    }
  });
}

export async function captureStubbornCancellation() {
  return withCaptureWorkspace("stubborn_cancel", async (context) => {
    const { thread, environment } = createSyntheticThread(context);
    const abortController = new AbortController();
    let capturedPID = null;
    let drainPromise = null;
    let iterator = null;
    let forcedCleanup = null;

    try {
      const streamed = await withWallClockDeadline(
        thread.runStreamed(PROTOCOL_GOLDEN_APPLICATION_PROMPT, {
          outputSchema: PROTOCOL_GOLDEN_OUTPUT_SCHEMA,
          signal: abortController.signal,
        }),
        "stubborn Codex SDK cancellation stream creation",
      );
      iterator = streamed.events[Symbol.asyncIterator]();
      const firstEvent = await withWallClockDeadline(
        iterator.next(),
        "stubborn Codex SDK cancellation first event",
      );
      const startedCapture = await waitForCapture(
        context.capturePath,
        (capture) => Number.isInteger(capture.pid),
        "stubborn Codex SDK cancellation child PID",
      );
      capturedPID = validateCapturedPID(startedCapture, context);

      abortController.abort();
      drainPromise = captureIteratorFailure(iterator);
      await waitForCapture(
        context.capturePath,
        (capture) => capture.phase === "sigterm_ignored" && capture.sigterm_count >= 1,
        "stubborn Codex SDK SIGTERM capture",
      );
      const drainObservation = await observePromiseSettlement(
        drainPromise,
        STUBBORN_OBSERVATION_MILLISECONDS,
      );
      const observedCapture = await readCapture(context.capturePath);
      const processAliveAfterAbort = isProcessAlive(capturedPID);

      forcedCleanup = await forceKillAndWait(capturedPID);
      const failure = await withWallClockDeadline(
        drainPromise,
        "stubborn Codex SDK cancellation drain after forced cleanup",
      );
      const schemaArtifacts = await schemaArtifactStatus(observedCapture);

      return {
        capture: observedCapture,
        capturedPID,
        drainSettledBeforeForcedKill: drainObservation.settled,
        environment,
        expectedPaths: publicPaths(context),
        ...schemaArtifacts,
        failure,
        firstEvent,
        forcedKillSent: forcedCleanup.killSent,
        processAliveAfterAbort,
        processAliveAfterCleanup: isProcessAlive(capturedPID),
      };
    } finally {
      if (!abortController.signal.aborted) {
        abortController.abort();
      }
      await ensureCancellationProbeCleanup({
        capturePath: context.capturePath,
        capturedPID,
        context,
        drainPromise,
        iterator,
      });
    }
  });
}

export async function captureSDKFailure(behavior) {
  if (!FAILURE_BEHAVIORS.has(behavior)) {
    throw new TypeError(`unsupported synthetic failure behavior: ${behavior}`);
  }

  return withCaptureWorkspace(behavior, async (context) => {
    const { thread, environment } = createSyntheticThread(context);
    const failure = await captureRejection(() => thread.run(PROTOCOL_GOLDEN_APPLICATION_PROMPT));
    const capture = await readCapture(context.capturePath);
    const schemaArtifacts = await schemaArtifactStatus(capture);

    return {
      capture,
      environment,
      expectedPaths: publicPaths(context),
      ...schemaArtifacts,
      failure,
    };
  });
}

export async function captureUnicodeOutputSDKInvocation(behavior) {
  if (!UNICODE_OUTPUT_BEHAVIORS.has(behavior)) {
    throw new TypeError(`unsupported synthetic Unicode behavior: ${behavior}`);
  }

  return withCaptureWorkspace(behavior, async (context) => {
    const { thread, environment } = createSyntheticThread(context);
    let failure = null;
    let turn = null;
    try {
      turn = await thread.run(PROTOCOL_GOLDEN_APPLICATION_PROMPT, {
        outputSchema: PROTOCOL_GOLDEN_OUTPUT_SCHEMA,
      });
    } catch (error) {
      failure = serializeError(error);
    }
    const capture = await readCapture(context.capturePath);
    const schemaArtifacts = await schemaArtifactStatus(capture);

    return {
      capture,
      environment,
      expectedPaths: publicPaths(context),
      ...schemaArtifacts,
      failure,
      nodeIdentity: Object.freeze({
        architecture: process.arch,
        executablePath: process.execPath,
        version: process.version,
      }),
      outcome: failure === null ? "completed" : "failed",
      turn,
    };
  });
}

function createSyntheticThread(context) {
  const environment = Object.freeze({
    CODEX_HOME: context.codexHome,
    FUMINIWA_CAPTURE_PATH: context.capturePath,
    FUMINIWA_FAKE_BEHAVIOR: context.behavior,
    LANG: "C.UTF-8",
    TMPDIR: context.requestTemporaryDirectory,
  });
  const codex = new Codex({
    codexPathOverride: context.fakeCLIPath,
    env: environment,
  });
  const thread = codex.startThread({
    model: PROTOCOL_GOLDEN_MODEL_ID,
    sandboxMode: "read-only",
    workingDirectory: context.workingDirectory,
    skipGitRepoCheck: true,
    networkAccessEnabled: false,
    webSearchMode: "disabled",
    approvalPolicy: "never",
  });
  return { environment, thread };
}

async function withCaptureWorkspace(behavior, operation) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "fuminiwa-sdk-capture-"));
  const context = {
    behavior,
    root,
    capturePath: path.join(root, "capture.json"),
    codexHome: path.join(root, "codex-home"),
    fakeCLIPath: path.join(root, "synthetic-codex"),
    requestTemporaryDirectory: path.join(root, "request-tmp"),
    workingDirectory: path.join(root, "request-cwd"),
  };
  await Promise.all([
    fs.mkdir(context.codexHome),
    fs.mkdir(context.requestTemporaryDirectory),
    fs.mkdir(context.workingDirectory),
  ]);
  if (/\s|[\r\n]/u.test(process.execPath)) {
    throw new Error("the synthetic executable requires a whitespace-free Node path");
  }
  await fs.writeFile(context.fakeCLIPath, `#!${process.execPath}\n${FAKE_CLI_SOURCE}`, {
    encoding: "utf8",
    mode: 0o700,
  });

  try {
    return await operation(context);
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
}

function publicPaths(context) {
  return Object.freeze({
    capturePath: context.capturePath,
    codexHome: context.codexHome,
    fakeCLIPath: context.fakeCLIPath,
    requestTemporaryDirectory: context.requestTemporaryDirectory,
    workingDirectory: context.workingDirectory,
  });
}

async function captureRejection(operation) {
  try {
    await operation();
  } catch (error) {
    return serializeError(error);
  }
  throw new Error("the synthetic SDK operation unexpectedly succeeded");
}

function serializeError(error) {
  return {
    code: typeof error?.code === "string" ? error.code : null,
    message: error instanceof Error ? error.message : String(error),
    name: error instanceof Error ? error.name : typeof error,
  };
}

function captureIteratorFailure(iterator) {
  return captureRejection(async () => {
    while (!(await iterator.next()).done) {
      // Drain until the SDK reports cancellation.
    }
  });
}

async function withWallClockDeadline(
  operationPromise,
  label,
  timeoutMilliseconds = CANCELLATION_STEP_TIMEOUT_MILLISECONDS,
) {
  let timeoutID;
  const deadlinePromise = new Promise((_, reject) => {
    timeoutID = setTimeout(() => {
      reject(new Error(`${label} exceeded ${timeoutMilliseconds}ms`));
    }, timeoutMilliseconds);
  });
  try {
    return await Promise.race([operationPromise, deadlinePromise]);
  } finally {
    clearTimeout(timeoutID);
  }
}

async function observePromiseSettlement(operationPromise, timeoutMilliseconds) {
  let timeoutID;
  const pendingMarker = Symbol("pending");
  const deadlinePromise = new Promise((resolve) => {
    timeoutID = setTimeout(() => resolve(pendingMarker), timeoutMilliseconds);
  });
  const settlementPromise = operationPromise.then(
    (value) => ({ status: "fulfilled", value }),
    (error) => ({ error, status: "rejected" }),
  );
  try {
    const outcome = await Promise.race([settlementPromise, deadlinePromise]);
    return outcome === pendingMarker ? { settled: false } : { ...outcome, settled: true };
  } finally {
    clearTimeout(timeoutID);
  }
}

async function waitForCapture(capturePath, predicate, label) {
  const deadline = Date.now() + CANCELLATION_STEP_TIMEOUT_MILLISECONDS;
  let lastError = null;
  while (Date.now() <= deadline) {
    try {
      const capture = await readCapture(capturePath);
      if (predicate(capture)) {
        return capture;
      }
    } catch (error) {
      lastError = error;
    }
    await delay(PROCESS_POLL_INTERVAL_MILLISECONDS);
  }
  throw new Error(`${label} exceeded ${CANCELLATION_STEP_TIMEOUT_MILLISECONDS}ms`, {
    cause: lastError,
  });
}

function validateCapturedPID(capture, context) {
  if (capture.executable_path !== context.fakeCLIPath) {
    throw new Error("refusing to manage a process that is not the synthetic fake CLI");
  }
  const pid = capture.pid;
  if (!Number.isSafeInteger(pid) || pid <= 1 || pid === process.pid) {
    throw new Error("refusing to manage an invalid synthetic fake CLI PID");
  }
  return pid;
}

function isProcessAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    if (error?.code === "ESRCH") {
      return false;
    }
    throw error;
  }
}

async function forceKillAndWait(pid) {
  if (!Number.isSafeInteger(pid) || pid <= 1 || pid === process.pid) {
    throw new Error("refusing to force-kill an invalid synthetic fake CLI PID");
  }
  if (!isProcessAlive(pid)) {
    return { killSent: false };
  }

  let killSent = false;
  try {
    process.kill(pid, "SIGKILL");
    killSent = true;
  } catch (error) {
    if (error?.code !== "ESRCH") {
      throw error;
    }
  }
  if (!(await waitForProcessExit(pid))) {
    throw new Error(`synthetic fake CLI PID ${pid} survived bounded SIGKILL cleanup`);
  }
  return { killSent };
}

async function waitForProcessExit(pid) {
  const deadline = Date.now() + PROCESS_EXIT_TIMEOUT_MILLISECONDS;
  while (Date.now() <= deadline) {
    if (!isProcessAlive(pid)) {
      return true;
    }
    await delay(PROCESS_POLL_INTERVAL_MILLISECONDS);
  }
  return !isProcessAlive(pid);
}

async function ensureCancellationProbeCleanup({
  capturePath,
  capturedPID,
  context,
  drainPromise,
  iterator,
}) {
  let cleanupPID = capturedPID;
  if (cleanupPID === null) {
    try {
      const capture = await waitForCapture(
        capturePath,
        (candidate) => Number.isInteger(candidate.pid),
        "cancellation cleanup child PID",
      );
      cleanupPID = validateCapturedPID(capture, context);
    } catch {
      // A pre-spawn SDK failure has no child to recover. The bounded iterator
      // cleanup below remains mandatory and prevents this path from hanging.
    }
  }

  if (cleanupPID !== null && isProcessAlive(cleanupPID)) {
    if (!(await waitForProcessExit(cleanupPID))) {
      await forceKillAndWait(cleanupPID);
    }
  }

  if (drainPromise !== null) {
    await withWallClockDeadline(drainPromise, "cancellation cleanup drain");
  } else if (iterator !== null) {
    await withWallClockDeadline(iterator.return(), "cancellation iterator return");
  }

  if (cleanupPID !== null && isProcessAlive(cleanupPID)) {
    await forceKillAndWait(cleanupPID);
  }
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function readCapture(capturePath) {
  return JSON.parse(await fs.readFile(capturePath, "utf8"));
}

async function pathExists(candidatePath) {
  if (candidatePath === null) {
    return false;
  }
  try {
    await fs.access(candidatePath);
    return true;
  } catch {
    return false;
  }
}

async function schemaArtifactStatus(capture) {
  if (capture.output_schema_path === null) {
    return {
      outputSchemaDirectoryExistsAfterRun: false,
      outputSchemaFileExistsAfterRun: false,
    };
  }
  return {
    outputSchemaDirectoryExistsAfterRun: await pathExists(
      path.dirname(capture.output_schema_path),
    ),
    outputSchemaFileExistsAfterRun: await pathExists(capture.output_schema_path),
  };
}
