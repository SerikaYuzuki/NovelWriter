import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { PassThrough, Writable } from "node:stream";
import test from "node:test";

import { MAXIMUM_PROCESS_BYTES, parseEventFrame } from "../src/protocol.mjs";
import { run } from "../src/main.mjs";

const mainPath = new URL("../src/main.mjs", import.meta.url);
const startFixture = readFileSync(
  new URL("../fixtures/protocol-v1/start.jsonl", import.meta.url),
);
const helloFixture = readFileSync(
  new URL("../fixtures/protocol-v1/hello.jsonl", import.meta.url),
);
const validRequest = Buffer.concat([helloFixture, startFixture]);

test("CLI reserves stdout for protocol frames and redacts the unavailable executor", () => {
  const result = spawnSync(process.execPath, [mainPath.pathname], {
    input: validRequest,
    encoding: "buffer",
  });

  assert.equal(result.status, 0);
  assert.equal(result.stderr.length, 0);
  const lines = result.stdout.subarray(0, -1).toString("utf8").split("\n");
  const events = lines.map((line) => parseEventFrame(Buffer.from(line, "utf8")));
  assert.deepEqual(
    events.map((event) => event.type),
    ["ready", "started", "failed"],
  );
  assert.equal(events.at(-1).code, "provider_unavailable");
  assert.equal(result.stdout.includes(Buffer.from("application_prompt")), false);
});

test("CLI emits nothing for malformed input before a request ID is accepted", () => {
  const result = spawnSync(process.execPath, [mainPath.pathname], {
    input: Buffer.from("{malformed}\n", "utf8"),
    encoding: "buffer",
  });

  assert.equal(result.status, 2);
  assert.equal(result.stdout.length, 0);
  assert.equal(result.stderr.length, 0);
});

test("CLI rejects start before hello without a ready or request event", () => {
  const result = spawnSync(process.execPath, [mainPath.pathname], {
    input: startFixture,
    encoding: "buffer",
  });

  assert.equal(result.status, 2);
  assert.equal(result.stdout.length, 0);
  assert.equal(result.stderr.length, 0);
});

test("CLI emits one redacted terminal for malformed input after start", () => {
  const result = spawnSync(process.execPath, [mainPath.pathname], {
    input: Buffer.concat([validRequest, Buffer.from("{malformed}\n", "utf8")]),
    encoding: "buffer",
  });

  assert.equal(result.status, 2);
  assert.equal(result.stderr.length, 0);
  const lines = result.stdout.subarray(0, -1).toString("utf8").split("\n");
  const events = lines.map((line) => parseEventFrame(Buffer.from(line, "utf8")));
  assert.deepEqual(
    events.map((event) => event.type),
    ["ready", "started", "failed"],
  );
  assert.equal(events.at(-1).code, "invalid_response");
});

test("CLI enforces the aggregate stdin cap before parsing any prompt-bearing frame", () => {
  const result = spawnSync(process.execPath, [mainPath.pathname], {
    input: Buffer.alloc(MAXIMUM_PROCESS_BYTES + 1, 0x20),
    encoding: "buffer",
  });

  assert.equal(result.status, 2);
  assert.equal(result.stdout.length, 0);
  assert.equal(result.stderr.length, 0);
});

test("an output channel failure aborts a running executor and settles without another frame", async () => {
  const input = new PassThrough();
  const writtenFrames = [];
  const output = new Writable({
    write(chunk, _encoding, callback) {
      writtenFrames.push(Buffer.from(chunk));
      callback();
    },
  });
  let upstreamSignal;
  let announceExecution;
  const executionStarted = new Promise((resolve) => {
    announceExecution = resolve;
  });
  const runPromise = run({
    input,
    output,
    execute: async (_providerInput, { signal }) => {
      upstreamSignal = signal;
      announceExecution();
      return new Promise(() => {});
    },
  });

  input.write(validRequest);
  await executionStarted;
  output.emit("error", new Error("simulated EPIPE"));
  const exitCode = await runPromise;

  assert.equal(exitCode, 1);
  assert.equal(upstreamSignal.aborted, true);
  assert.equal(writtenFrames.length, 2);
  assert.deepEqual(
    writtenFrames.map((frame) =>
      parseEventFrame(frame.subarray(0, -1)).type),
    ["ready", "started"],
  );
});
