import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import test from "node:test";

import {
  JSONLineFramer,
  MAXIMUM_JSON_DEPTH,
  MAXIMUM_FRAME_BYTES,
  ProtocolError,
  decodeFrame,
  encodeEventFrame,
  parseCommandFrame,
  parseEventFrame,
} from "../src/protocol.mjs";

const fixturesURL = new URL("../fixtures/protocol-v1/", import.meta.url);

async function fixtureBytes(name) {
  return readFile(new URL(name, fixturesURL));
}

async function fixtureObject(name) {
  const bytes = await fixtureBytes(name);
  return JSON.parse(bytes.toString("utf8"));
}

test("golden command fixtures satisfy the strict v1 contract", async () => {
  const hello = parseCommandFrame((await fixtureBytes("hello.jsonl")).subarray(0, -1));
  const start = parseCommandFrame((await fixtureBytes("start.jsonl")).subarray(0, -1));
  const cancel = parseCommandFrame((await fixtureBytes("cancel.jsonl")).subarray(0, -1));

  assert.equal(hello.type, "hello");
  assert.equal(start.type, "start");
  assert.equal(start.input_character_count > 0, true);
  assert.equal(cancel.type, "cancel");
  assert.equal(hello.request_id, start.request_id);
  assert.equal(cancel.request_id, hello.request_id);
});

test("golden event fixtures satisfy the strict v1 contract", async () => {
  for (const name of ["ready.jsonl", "started.jsonl", "completed.jsonl", "failed.jsonl"]) {
    const bytes = await fixtureBytes(name);
    const event = parseEventFrame(bytes.subarray(0, -1));
    assert.equal(event.version, 1);
  }
});

test("incremental framing preserves frames across arbitrary byte boundaries", async () => {
  const input = Buffer.concat([
    await fixtureBytes("hello.jsonl"),
    await fixtureBytes("start.jsonl"),
    await fixtureBytes("cancel.jsonl"),
  ]);
  const framer = new JSONLineFramer();
  const frames = [];

  for (const byte of input) {
    frames.push(...framer.push(Uint8Array.of(byte)));
  }
  framer.finish();

  assert.equal(frames.length, 3);
  assert.deepEqual(
    frames.map((frame) => parseCommandFrame(frame).type),
    ["hello", "start", "cancel"],
  );
});

test("framing accepts exactly the byte limit and rejects one byte more", () => {
  const exactFramer = new JSONLineFramer();
  const exactFrames = exactFramer.push(Buffer.concat([Buffer.alloc(MAXIMUM_FRAME_BYTES, 0x20), Buffer.of(0x0a)]));
  assert.equal(exactFrames.length, 1);
  assert.equal(exactFrames[0].length, MAXIMUM_FRAME_BYTES);
  exactFramer.finish();

  const oversizedFramer = new JSONLineFramer();
  assert.throws(
    () => oversizedFramer.push(Buffer.alloc(MAXIMUM_FRAME_BYTES + 1, 0x20)),
    ProtocolError,
  );
});

test("empty lines, CRLF, BOM, invalid UTF-8, malformed JSON, and missing LF fail closed", async () => {
  const emptyFramer = new JSONLineFramer();
  const [emptyFrame] = emptyFramer.push(Buffer.of(0x0a));
  assert.throws(() => parseCommandFrame(emptyFrame), ProtocolError);

  const startBytes = await fixtureBytes("start.jsonl");
  const crlfFramer = new JSONLineFramer();
  const [crlfFrame] = crlfFramer.push(
    Buffer.concat([startBytes.subarray(0, -1), Buffer.from("\r\n", "ascii")]),
  );
  assert.throws(() => parseCommandFrame(crlfFrame), ProtocolError);

  assert.throws(
    () =>
      parseCommandFrame(
        Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), startBytes.subarray(0, -1)]),
      ),
    ProtocolError,
  );
  assert.throws(() => parseCommandFrame(Buffer.from([0xc3, 0x28])), ProtocolError);
  assert.throws(() => parseCommandFrame(Buffer.from("{", "utf8")), ProtocolError);

  const unfinishedFramer = new JSONLineFramer();
  unfinishedFramer.push(startBytes.subarray(0, -1));
  assert.throws(() => unfinishedFramer.finish(), ProtocolError);
});

test("commands reject unknown fields, versions, enums, IDs, budgets, and incorrect counts", async () => {
  const start = await fixtureObject("start.jsonl");
  const mutations = [
    { ...start, extra: true },
    { ...start, version: 2 },
    { ...start, provider_id: "openrouter" },
    { ...start, request_id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaA" },
    { ...start, input_utf8_byte_count: start.input_utf8_byte_count + 1 },
    { ...start, budget: { ...start.budget, maximum_output_tokens: 8_193 } },
    { ...start, budget: { ...start.budget, maximum_warnings: 0 } },
  ];

  for (const candidate of mutations) {
    assert.throws(
      () => parseCommandFrame(Buffer.from(JSON.stringify(candidate), "utf8")),
      ProtocolError,
    );
  }
});

test("model, application IDs, prompt, and schema reject blank or fallback-prone values", async () => {
  const start = await fixtureObject("start.jsonl");
  const withPayload = (changes) => {
    const candidate = { ...start, ...changes };
    candidate.input_character_count = 1;
    candidate.input_utf8_byte_count =
      Buffer.byteLength(candidate.application_prompt, "utf8") +
      Buffer.byteLength(candidate.application_response_schema, "utf8");
    return Buffer.from(JSON.stringify(candidate), "utf8");
  };

  for (const modelID of ["", " ", "-fallback", "モデル", "model name", "a".repeat(129)]) {
    assert.throws(() => parseCommandFrame(withPayload({ model_id: modelID })), ProtocolError);
  }
  for (const [field, values] of [
    ["application_instruction_id", ["", " ", "Upper", "-fallback", "a/b", "a".repeat(129)]],
    ["application_response_schema_id", ["", " ", "Upper", "-fallback", "a/b", "a".repeat(129)]],
  ]) {
    for (const value of values) {
      assert.throws(() => parseCommandFrame(withPayload({ [field]: value })), ProtocolError);
    }
  }
  for (const applicationPrompt of ["", " \t", "\u0085", "\u3000", "\ufeff"]) {
    assert.throws(
      () => parseCommandFrame(withPayload({ application_prompt: applicationPrompt })),
      ProtocolError,
    );
  }
  for (const applicationResponseSchema of ["", " \t", "\u0085", "\u3000", "\ufeff"]) {
    assert.throws(
      () =>
        parseCommandFrame(
          withPayload({ application_response_schema: applicationResponseSchema }),
        ),
      ProtocolError,
    );
  }

  assert.equal(
    parseCommandFrame(withPayload({ model_id: "gpt-5.3-codex/test:v1" })).model_id,
    "gpt-5.3-codex/test:v1",
  );
  assert.equal(
    parseCommandFrame(withPayload({ application_prompt: "\u200b" })).application_prompt,
    "\u200b",
  );
});

test("character counts remain Swift-owned while UTF-8 byte counts are independently checked", async () => {
  const start = await fixtureObject("start.jsonl");
  const prompt = "か\u3099👨‍👩‍👧‍👦";
  const schema = "{}";
  const candidate = {
    ...start,
    application_prompt: prompt,
    application_response_schema: schema,
    input_character_count: 1,
    input_utf8_byte_count: Buffer.byteLength(prompt, "utf8") + Buffer.byteLength(schema, "utf8"),
  };

  const parsed = parseCommandFrame(Buffer.from(JSON.stringify(candidate), "utf8"));
  assert.equal(parsed.input_character_count, 1);
});

test("one-byte prompt and schema tampering is caught by the sealed UTF-8 count", async () => {
  const start = await fixtureObject("start.jsonl");
  for (const candidate of [
    { ...start, application_prompt: `${start.application_prompt}x` },
    { ...start, application_response_schema: `${start.application_response_schema}x` },
  ]) {
    assert.throws(
      () => parseCommandFrame(Buffer.from(JSON.stringify(candidate), "utf8")),
      ProtocolError,
    );
  }
});

test("opaque prompt, schema, and IDs are preserved when their confirmed counts are updated", async () => {
  const start = await fixtureObject("start.jsonl");
  const prompt = `${start.application_prompt}x`;
  const schema = `${start.application_response_schema}x`;
  const candidate = {
    ...start,
    application_instruction_id: `${start.application_instruction_id}x`,
    application_prompt: prompt,
    application_response_schema_id: `${start.application_response_schema_id}x`,
    application_response_schema: schema,
    input_character_count: start.input_character_count + 2,
    input_utf8_byte_count: Buffer.byteLength(prompt, "utf8") + Buffer.byteLength(schema, "utf8"),
  };

  const parsed = parseCommandFrame(Buffer.from(JSON.stringify(candidate), "utf8"));
  assert.equal(parsed.application_instruction_id, candidate.application_instruction_id);
  assert.equal(parsed.application_prompt, candidate.application_prompt);
  assert.equal(parsed.application_response_schema_id, candidate.application_response_schema_id);
  assert.equal(parsed.application_response_schema, candidate.application_response_schema);
});

test("every v1 budget field enforces zero, exact maximum, and maximum plus one", async () => {
  const start = await fixtureObject("start.jsonl");
  const maxima = {
    maximum_input_characters: 20_000,
    maximum_input_utf8_bytes: 80_000,
    maximum_output_characters: 20_000,
    maximum_output_utf8_bytes: 80_000,
    maximum_output_tokens: 8_192,
    maximum_warnings: 20,
    timeout_seconds: 120,
  };

  for (const [field, maximum] of Object.entries(maxima)) {
    const withBudgetValue = (value) =>
      Buffer.from(
        JSON.stringify({ ...start, budget: { ...start.budget, [field]: value } }),
        "utf8",
      );
    assert.throws(() => parseCommandFrame(withBudgetValue(0)), ProtocolError, `${field}=0`);
    assert.equal(parseCommandFrame(withBudgetValue(maximum)).budget[field], maximum);
    assert.throws(
      () => parseCommandFrame(withBudgetValue(maximum + 1)),
      ProtocolError,
      `${field}=max+1`,
    );
  }
});

test("duplicate JSON members, fractional, exponential, and unsafe numbers are rejected pre-parse", async () => {
  const startText = (await fixtureBytes("start.jsonl")).subarray(0, -1).toString("utf8");
  const duplicateRoot = startText.replace('{"version":1,', '{"version":1,"version":1,');
  const escapedDuplicateRoot = startText.replace(
    '"request_id":',
    '"request_\\u0069d":"duplicate","request_id":',
  );
  const duplicateBudget = startText.replace(
    '"budget":{"maximum_input_characters":20000,',
    '"budget":{"maximum_input_characters":20000,"maximum_input_characters":20000,',
  );
  const escapedDuplicateBudget = startText.replace(
    '"budget":{"maximum_input_characters":20000,',
    '"budget":{"maximum_\\u0069nput_characters":20000,"maximum_input_characters":20000,',
  );
  const fractional = startText.replace('"version":1', '"version":1.0');
  const exponential = startText.replace('"version":1', '"version":1e0');
  const unsafe = startText.replace('"version":1', '"version":9007199254740992');
  const leadingZero = startText.replace('"version":1', '"version":01');

  for (const candidate of [
    duplicateRoot,
    escapedDuplicateRoot,
    duplicateBudget,
    escapedDuplicateBudget,
    fractional,
    exponential,
    unsafe,
    leadingZero,
  ]) {
    assert.throws(() => parseCommandFrame(Buffer.from(candidate, "utf8")), ProtocolError);
  }
});

test("JSON container depth accepts 64 and rejects 65", () => {
  const nestedArray = (depth) => `${"[".repeat(depth)}0${"]".repeat(depth)}`;
  const nestedObject = (depth) => `${'{"value":'.repeat(depth)}0${"}".repeat(depth)}`;

  assert.doesNotThrow(() =>
    decodeFrame(Buffer.from(nestedArray(MAXIMUM_JSON_DEPTH), "utf8")),
  );
  assert.doesNotThrow(() =>
    decodeFrame(Buffer.from(nestedObject(MAXIMUM_JSON_DEPTH), "utf8")),
  );
  assert.throws(
    () => decodeFrame(Buffer.from(nestedArray(MAXIMUM_JSON_DEPTH + 1), "utf8")),
    ProtocolError,
  );
  assert.throws(
    () => decodeFrame(Buffer.from(nestedObject(MAXIMUM_JSON_DEPTH + 1), "utf8")),
    ProtocolError,
  );
});

test("escaped unpaired UTF-16 surrogates fail while a valid pair is accepted", () => {
  assert.throws(() => decodeFrame(Buffer.from('{"\\uD800":1}', "utf8")), ProtocolError);
  assert.throws(
    () => decodeFrame(Buffer.from('{"value":"\\uD800"}', "utf8")),
    ProtocolError,
  );
  assert.throws(
    () => decodeFrame(Buffer.from('{"value":"\\uDC00"}', "utf8")),
    ProtocolError,
  );
  assert.deepEqual(decodeFrame(Buffer.from('{"value":"\\uD83D\\uDE00"}', "utf8")), {
    value: "😀",
  });
});

test("events reject unknown fields, usage fields, and failure codes", async () => {
  const completed = await fixtureObject("completed.jsonl");
  const failed = await fixtureObject("failed.jsonl");

  assert.throws(
    () => parseEventFrame(Buffer.from(JSON.stringify({ ...completed, extra: true }))),
    ProtocolError,
  );
  assert.throws(
    () => encodeEventFrame({ ...completed, structured_output: "\ud800" }),
    ProtocolError,
  );
  const duplicateUsage = JSON.stringify(completed).replace(
    '"usage":{"input_tokens":2,',
    '"usage":{"input_\\u0074okens":2,"input_tokens":2,',
  );
  assert.throws(() => parseEventFrame(Buffer.from(duplicateUsage)), ProtocolError);
  assert.throws(
    () =>
      parseEventFrame(
        Buffer.from(
          JSON.stringify({ ...completed, usage: { ...completed.usage, cached_tokens: 1 } }),
        ),
      ),
    ProtocolError,
  );
  assert.throws(
    () => parseEventFrame(Buffer.from(JSON.stringify({ ...failed, code: "raw_sdk_error" }))),
    ProtocolError,
  );
});

test("ready runtime identity is exact and mock mode cannot claim SDK artifacts", async () => {
  const ready = await fixtureObject("ready.jsonl");
  const canonicalSyntheticSRI = `sha512-${Buffer.alloc(64, 0x61).toString("base64")}`;
  assert.equal(parseEventFrame(Buffer.from(JSON.stringify(ready))).runtime.mode, "mock");

  const invalidReadyValues = [
    { ...ready, runtime: { ...ready.runtime, unknown: null } },
    { ...ready, runtime: { ...ready.runtime, architecture: "riscv64" } },
    { ...ready, runtime: { ...ready.runtime, sdk_version: "0.147.0" } },
    { ...ready, runtime: { ...ready.runtime, sidecar_bundle_sha256: "A".repeat(64) } },
  ];
  for (const candidate of invalidReadyValues) {
    assert.throws(
      () => parseEventFrame(Buffer.from(JSON.stringify(candidate), "utf8")),
      ProtocolError,
    );
  }

  const sdkRuntime = {
    mode: "codex_sdk",
    sidecar_version: "1.0.0-test",
    sidecar_bundle_sha256: "a".repeat(64),
    node_version: "22.0.0-test",
    node_sha256: "b".repeat(64),
    architecture: "arm64",
    sdk_version: "0.147.0-test",
    sdk_integrity: canonicalSyntheticSRI,
    cli_version: "0.147.0-test",
    cli_sha256: "c".repeat(64),
  };
  const parsedSDKReady = parseEventFrame(
    Buffer.from(JSON.stringify({ ...ready, runtime: sdkRuntime }), "utf8"),
  );
  assert.equal(parsedSDKReady.runtime.mode, "codex_sdk");
  assert.throws(
    () =>
      parseEventFrame(
        Buffer.from(
          JSON.stringify({
            ...ready,
            runtime: { ...sdkRuntime, sdk_integrity: "sha256-YQ==" },
          }),
          "utf8",
        ),
      ),
    ProtocolError,
  );
  for (const invalidIntegrity of [
    "sha512-YQ==",
    canonicalSyntheticSRI.slice(0, -2),
    canonicalSyntheticSRI.replace("sha512-", "sha256-"),
  ]) {
    assert.throws(
      () =>
        parseEventFrame(
          Buffer.from(
            JSON.stringify({
              ...ready,
              runtime: { ...sdkRuntime, sdk_integrity: invalidIntegrity },
            }),
            "utf8",
          ),
        ),
      ProtocolError,
    );
  }

  assert.equal(
    parseEventFrame(
      Buffer.from(
        JSON.stringify({
          ...ready,
          runtime: {
            ...ready.runtime,
            sidecar_version: "a".repeat(256),
            node_version: "b".repeat(256),
          },
        }),
        "utf8",
      ),
    ).runtime.sidecar_version.length,
    256,
  );
  for (const [field, value] of [
    ["sidecar_version", ""],
    ["sidecar_version", "a".repeat(257)],
    ["node_version", "node version"],
    ["node_version", "ノード"],
  ]) {
    assert.throws(
      () =>
        parseEventFrame(
          Buffer.from(
            JSON.stringify({ ...ready, runtime: { ...ready.runtime, [field]: value } }),
            "utf8",
          ),
        ),
      ProtocolError,
    );
  }

  for (const [field, value] of [
    ["sdk_version", "sdk version"],
    ["sdk_version", "s".repeat(257)],
    ["cli_version", "CLI版"],
    ["cli_version", "c".repeat(257)],
    ["sdk_integrity", `sha512-${"A".repeat(250)}`],
  ]) {
    assert.throws(
      () =>
        parseEventFrame(
          Buffer.from(
            JSON.stringify({ ...ready, runtime: { ...sdkRuntime, [field]: value } }),
            "utf8",
          ),
        ),
      ProtocolError,
    );
  }
});

test("fixture paths remain local to the synthetic protocol corpus", () => {
  assert.equal(
    fileURLToPath(fixturesURL).endsWith("Sidecars/Codex/fixtures/protocol-v1/"),
    true,
  );
});
