import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { ProtocolError, parseCommandFrame, parseEventFrame } from "../src/protocol.mjs";
import { CodexSidecarSession, SidecarFailure } from "../src/session.mjs";

const fixturesURL = new URL("../fixtures/protocol-v1/", import.meta.url);

async function parsedFixture(name, parser) {
  const bytes = await readFile(new URL(name, fixturesURL));
  return parser(bytes.subarray(0, -1));
}

async function commands() {
  return {
    hello: await parsedFixture("hello.jsonl", parseCommandFrame),
    start: await parsedFixture("start.jsonl", parseCommandFrame),
    cancel: await parsedFixture("cancel.jsonl", parseCommandFrame),
  };
}

const goldenReady = await parsedFixture("ready.jsonl", parseEventFrame);

async function successfulCompletion() {
  const event = await parsedFixture("completed.jsonl", parseEventFrame);
  return { structured_output: event.structured_output, usage: event.usage };
}

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

function makeSession(execute, { runtimeIdentity = goldenReady.runtime } = {}) {
  const events = [];
  const session = new CodexSidecarSession({
    execute,
    runtimeIdentity,
    emit(event) {
      events.push(event);
    },
  });
  return { session, events };
}

function attestAndStart(session, commandSet) {
  session.handleCommand(commandSet.hello);
  session.handleCommand(commandSet.start);
}

test("valid start emits started followed by one completed terminal", async () => {
  const commandSet = await commands();
  const { start } = commandSet;
  const completion = await successfulCompletion();
  const { session, events } = makeSession(async () => completion);

  attestAndStart(session, commandSet);
  const terminal = await session.waitForTerminal();

  assert.equal(terminal.type, "completed");
  assert.deepEqual(
    events.map((event) => event.type),
    ["ready", "started", "completed"],
  );
  assert.equal(events.every((event) => event.request_id === start.request_id), true);
});

test("hello emits the exact injected prompt-free ready attestation before start", async () => {
  const { hello } = await commands();
  const { session, events } = makeSession(async () => new Promise(() => {}));

  session.handleCommand(hello);

  assert.deepEqual(events, [goldenReady]);
  assert.equal(JSON.stringify(events).includes("application_prompt"), false);
  assert.equal(session.state, "attested");
});

test("started is emitted before the mock executor may perform a side effect", async () => {
  const commandSet = await commands();
  let observedEventTypes = [];
  let events;
  const built = makeSession(async () => {
    observedEventTypes = events.map((event) => event.type);
    return successfulCompletion();
  });
  events = built.events;

  attestAndStart(built.session, commandSet);
  await built.session.waitForTerminal();

  assert.deepEqual(observedEventTypes, ["ready", "started"]);
});

test("mock executor receives only the exact provider-facing confirmed values", async () => {
  const commandSet = await commands();
  let received;
  const { session } = makeSession(async (providerInput) => {
    received = providerInput;
    return successfulCompletion();
  });

  attestAndStart(session, commandSet);
  await session.waitForTerminal();

  assert.deepEqual(Object.keys(received).sort(), [
    "application_prompt",
    "application_response_schema",
    "model_id",
  ]);
  assert.equal(received.model_id, commandSet.start.model_id);
  assert.equal(received.application_prompt, commandSet.start.application_prompt);
  assert.equal(
    received.application_response_schema,
    commandSet.start.application_response_schema,
  );
  assert.equal(Object.hasOwn(received, "request_id"), false);
  assert.equal(Object.hasOwn(received, "budget"), false);
});

test("cancel wins a start race and produces exactly one cancelled terminal", async () => {
  const commandSet = await commands();
  const { cancel } = commandSet;
  let executeCalls = 0;
  const { session, events } = makeSession(async () => {
    executeCalls += 1;
    return successfulCompletion();
  });

  attestAndStart(session, commandSet);
  session.handleCommand(cancel);
  const terminal = await session.waitForTerminal();
  await Promise.resolve();

  assert.equal(terminal.code, "cancelled");
  assert.equal(executeCalls, 0);
  assert.deepEqual(
    events.map((event) => event.type),
    ["ready", "started", "failed"],
  );
});

test("late provider completion is ignored after cancellation", async () => {
  const commandSet = await commands();
  const { cancel } = commandSet;
  const provider = deferred();
  let signal;
  const { session, events } = makeSession(async (_command, context) => {
    signal = context.signal;
    return provider.promise;
  });

  attestAndStart(session, commandSet);
  await Promise.resolve();
  session.handleCommand(cancel);
  const terminal = await session.waitForTerminal();
  provider.resolve(await successfulCompletion());
  await Promise.resolve();
  await Promise.resolve();

  assert.equal(signal.aborted, true);
  assert.equal(terminal.code, "cancelled");
  assert.equal(events.length, 3);
  assert.equal(events.at(-1).type, "failed");
});

test("a duplicate start fails the accepted request and ignores later completion", async () => {
  const commandSet = await commands();
  const { start } = commandSet;
  const provider = deferred();
  const { session, events } = makeSession(async () => provider.promise);

  attestAndStart(session, commandSet);
  await Promise.resolve();
  assert.throws(() => session.handleCommand(start), ProtocolError);
  const terminal = await session.waitForTerminal();
  provider.resolve(await successfulCompletion());
  await Promise.resolve();

  assert.equal(terminal.code, "invalid_response");
  assert.deepEqual(
    events.map((event) => event.type),
    ["ready", "started", "failed"],
  );
});

test("a duplicate cancel or late command cannot produce a second terminal", async () => {
  const commandSet = await commands();
  const { cancel } = commandSet;
  const { session, events } = makeSession(async () => new Promise(() => {}));

  attestAndStart(session, commandSet);
  session.handleCommand(cancel);
  await session.waitForTerminal();
  assert.throws(() => session.handleCommand(cancel), ProtocolError);

  assert.equal(events.filter((event) => event.type === "failed").length, 1);
  assert.equal(events.at(-1).code, "cancelled");
});

test("a mismatched cancel request ID fails the active request closed", async () => {
  const commandSet = await commands();
  const { cancel } = commandSet;
  const mismatched = {
    ...cancel,
    request_id: "00000000-0000-0000-0000-000000000002",
  };
  const { session, events } = makeSession(async () => new Promise(() => {}));

  attestAndStart(session, commandSet);
  assert.throws(() => session.handleCommand(mismatched), ProtocolError);
  const terminal = await session.waitForTerminal();

  assert.equal(terminal.code, "invalid_response");
  assert.equal(events.filter((event) => event.type === "failed").length, 1);
});

test("malformed input after request acceptance yields one redacted invalid_response", async () => {
  const commandSet = await commands();
  const { start } = commandSet;
  const { session, events } = makeSession(async () => new Promise(() => {}));

  attestAndStart(session, commandSet);
  assert.throws(() => session.handleCommand({ ...start, unknown: "secret" }), ProtocolError);
  const terminal = await session.waitForTerminal();

  assert.equal(terminal.code, "invalid_response");
  assert.equal(events.some((event) => Object.hasOwn(event, "unknown")), false);
});

test("typed failures remain fixed codes and generic internal errors fail closed", async () => {
  const commandSet = await commands();
  const typed = makeSession(async () => {
    throw new SidecarFailure("rate_limited");
  });
  attestAndStart(typed.session, commandSet);
  assert.equal((await typed.session.waitForTerminal()).code, "rate_limited");

  const generic = makeSession(async () => {
    throw new Error("raw SDK path and secret");
  });
  attestAndStart(generic.session, commandSet);
  assert.equal((await generic.session.waitForTerminal()).code, "invalid_response");
  assert.equal(JSON.stringify(generic.events).includes("raw SDK"), false);
});

test("malformed or over-budget provider completion is rejected before emission", async () => {
  const commandSet = await commands();
  const { start } = commandSet;
  const malformed = makeSession(async () => ({
    structured_output: "{}",
    usage: { input_tokens: null, output_tokens: 1, extra: 1 },
  }));
  attestAndStart(malformed.session, commandSet);
  assert.equal((await malformed.session.waitForTerminal()).code, "invalid_response");

  const overBudget = makeSession(async () => ({
    structured_output: "{}",
    usage: { input_tokens: null, output_tokens: start.budget.maximum_output_tokens + 1 },
  }));
  attestAndStart(overBudget.session, commandSet);
  assert.equal((await overBudget.session.waitForTerminal()).code, "invalid_response");
});

test("an unpaired surrogate in provider output becomes one redacted failure terminal", async () => {
  const commandSet = await commands();
  const { session, events } = makeSession(async () => ({
    structured_output: "\ud800",
    usage: { input_tokens: null, output_tokens: 1 },
  }));

  attestAndStart(session, commandSet);
  const terminal = await session.waitForTerminal();

  assert.equal(terminal.type, "failed");
  assert.equal(terminal.code, "invalid_response");
  assert.deepEqual(
    events.map((event) => event.type),
    ["ready", "started", "failed"],
  );
  assert.equal(events.filter((event) => event.type === "failed").length, 1);
  assert.equal(JSON.stringify(events).includes("\\ud800"), false);
});

test("JSON escaping expansion cannot claim a completed terminal without a wire frame", async () => {
  const commandSet = await commands();
  const { session, events } = makeSession(async () => ({
    structured_output: "\u0000".repeat(80_000),
    usage: { input_tokens: null, output_tokens: 1 },
  }));

  attestAndStart(session, commandSet);
  const terminal = await session.waitForTerminal();

  assert.equal(terminal.type, "failed");
  assert.equal(terminal.code, "invalid_response");
  assert.deepEqual(
    events.map((event) => event.type),
    ["ready", "started", "failed"],
  );
});

test("cancel before start is rejected without inventing a request ID or event", async () => {
  const { cancel } = await commands();
  const { session, events } = makeSession(async () => new Promise(() => {}));

  assert.throws(() => session.handleCommand(cancel), ProtocolError);
  assert.equal(session.hasAcceptedRequest, false);
  assert.deepEqual(events, []);
});

test("start before hello and invalid start after ready emit no request lifecycle event", async () => {
  const commandSet = await commands();
  const beforeHello = makeSession(async () => new Promise(() => {}));
  assert.throws(() => beforeHello.session.handleCommand(commandSet.start), ProtocolError);
  assert.deepEqual(beforeHello.events, []);

  const afterReady = makeSession(async () => new Promise(() => {}));
  afterReady.session.handleCommand(commandSet.hello);
  const mismatchedStart = {
    ...commandSet.start,
    request_id: "00000000-0000-0000-0000-000000000002",
  };
  assert.throws(() => afterReady.session.handleCommand(mismatchedStart), ProtocolError);
  assert.deepEqual(
    afterReady.events.map((event) => event.type),
    ["ready"],
  );
});

test("duplicate hello after attestation is rejected without started or failed", async () => {
  const { hello } = await commands();
  const { session, events } = makeSession(async () => new Promise(() => {}));

  session.handleCommand(hello);
  assert.throws(() => session.handleCommand(hello), ProtocolError);

  assert.deepEqual(
    events.map((event) => event.type),
    ["ready"],
  );
});

test("invalid runtime attestation emits no ready or failed frame", async () => {
  const { hello } = await commands();
  const { session, events } = makeSession(async () => new Promise(() => {}), {
    runtimeIdentity: { ...goldenReady.runtime, sdk_version: "0.147.0" },
  });

  assert.throws(() => session.handleCommand(hello), ProtocolError);
  assert.deepEqual(events, []);
  assert.equal(session.state, "awaiting_hello");
});

test("timeout emits one timed_out terminal and aborts the mock executor", async () => {
  const commandSet = await commands();
  const timedStart = {
    ...commandSet.start,
    budget: { ...commandSet.start.budget, timeout_seconds: 1 },
  };
  let signal;
  const { session, events } = makeSession(async (_command, context) => {
    signal = context.signal;
    return new Promise(() => {});
  });

  session.handleCommand(commandSet.hello);
  session.handleCommand(timedStart);
  const terminal = await session.waitForTerminal();

  assert.equal(terminal.code, "timed_out");
  assert.equal(signal.aborted, true);
  assert.equal(events.filter((event) => event.type === "failed").length, 1);
});

test("EOF while running cancels upstream and late completion remains ignored", async () => {
  const commandSet = await commands();
  const provider = deferred();
  let signal;
  const { session, events } = makeSession(async (_command, context) => {
    signal = context.signal;
    return provider.promise;
  });

  attestAndStart(session, commandSet);
  await Promise.resolve();
  session.handleInputEOF();
  const terminal = await session.waitForTerminal();
  provider.resolve(await successfulCompletion());
  await Promise.resolve();

  assert.equal(signal.aborted, true);
  assert.equal(terminal.code, "cancelled");
  assert.equal(events.filter((event) => event.type === "failed").length, 1);
});

test("EOF before start is a protocol error and EOF after terminal is idempotent", async () => {
  const commandSet = await commands();
  const { cancel } = commandSet;
  const beforeStart = makeSession(async () => new Promise(() => {}));
  assert.throws(() => beforeStart.session.handleInputEOF(), ProtocolError);
  assert.deepEqual(beforeStart.events, []);

  const afterTerminal = makeSession(async () => new Promise(() => {}));
  attestAndStart(afterTerminal.session, commandSet);
  afterTerminal.session.handleCommand(cancel);
  await afterTerminal.session.waitForTerminal();
  afterTerminal.session.handleInputEOF();
  assert.equal(afterTerminal.events.filter((event) => event.type === "failed").length, 1);
});
