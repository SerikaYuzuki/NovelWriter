import { Buffer } from "node:buffer";

import {
  encodeEventFrame,
  FAILURE_CODES,
  PROTOCOL_VERSION,
  ProtocolError,
  validateCommand,
  validateEvent,
} from "./protocol.mjs";

const failureCodeSet = new Set(FAILURE_CODES);

export class SidecarFailure extends Error {
  constructor(code) {
    if (!failureCodeSet.has(code)) {
      throw new TypeError("SidecarFailure requires a protocol failure code");
    }
    super(code);
    this.name = "SidecarFailure";
    this.code = code;
  }
}

function requireCompletionShape(candidate, budget) {
  if (candidate === null || typeof candidate !== "object" || Array.isArray(candidate)) {
    throw new SidecarFailure("invalid_response");
  }
  const keys = Object.keys(candidate);
  if (
    keys.length !== 2 ||
    !Object.hasOwn(candidate, "structured_output") ||
    !Object.hasOwn(candidate, "usage")
  ) {
    throw new SidecarFailure("invalid_response");
  }
  if (typeof candidate.structured_output !== "string") {
    throw new SidecarFailure("invalid_response");
  }

  const usage = candidate.usage;
  if (usage === null || typeof usage !== "object" || Array.isArray(usage)) {
    throw new SidecarFailure("invalid_response");
  }
  const usageKeys = Object.keys(usage);
  if (
    usageKeys.length !== 2 ||
    !Object.hasOwn(usage, "input_tokens") ||
    !Object.hasOwn(usage, "output_tokens") ||
    !(
      usage.input_tokens === null ||
      (Number.isSafeInteger(usage.input_tokens) && usage.input_tokens >= 0)
    ) ||
    !Number.isSafeInteger(usage.output_tokens) ||
    usage.output_tokens < 0
  ) {
    throw new SidecarFailure("invalid_response");
  }

  const outputUTF8Bytes = Buffer.byteLength(candidate.structured_output, "utf8");
  // Swift owns String.count validation. Node independently enforces only the
  // byte and provider-usage limits whose semantics are identical on both sides.
  if (
    outputUTF8Bytes > budget.maximum_output_utf8_bytes ||
    usage.output_tokens > budget.maximum_output_tokens
  ) {
    throw new SidecarFailure("invalid_response");
  }

  return {
    structured_output: candidate.structured_output,
    usage: {
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
    },
  };
}

export class CodexSidecarSession {
  #state = "awaiting_hello";
  #requestID = null;
  #abortController = null;
  #timeout = null;
  #execute;
  #emit;
  #runtimeIdentity;
  #resolveTerminal;
  #terminalPromise;

  constructor({ execute, emit, runtimeIdentity }) {
    if (typeof execute !== "function" || typeof emit !== "function") {
      throw new TypeError("execute and emit callbacks are required");
    }
    this.#execute = execute;
    this.#emit = emit;
    this.#runtimeIdentity = runtimeIdentity;
    this.#terminalPromise = new Promise((resolve) => {
      this.#resolveTerminal = resolve;
    });
  }

  get state() {
    return this.#state;
  }

  get hasAcceptedRequest() {
    return this.#requestID !== null;
  }

  waitForTerminal() {
    return this.#terminalPromise;
  }

  handleCommand(candidate) {
    let command;
    try {
      command = validateCommand(candidate);
    } catch (error) {
      this.handleProtocolFailure();
      throw error;
    }

    if (this.#state === "awaiting_hello") {
      if (command.type !== "hello") {
        throw new ProtocolError("the first command must be hello");
      }
      this.#attest(command);
      return;
    }

    if (this.#state === "attested") {
      if (command.type !== "start" || command.request_id !== this.#requestID) {
        throw new ProtocolError("start must match the attested request");
      }
      this.#start(command);
      return;
    }

    if (this.#state === "running") {
      if (command.type !== "cancel" || command.request_id !== this.#requestID) {
        this.handleProtocolFailure();
        throw new ProtocolError("invalid command for the active request");
      }
      this.#finishFailed("cancelled", { abort: true });
      return;
    }

    throw new ProtocolError("command received after the terminal event");
  }

  handleProtocolFailure() {
    if (this.#state !== "running") {
      return false;
    }
    this.#finishFailed("invalid_response", { abort: true });
    return true;
  }

  handleInputEOF() {
    if (this.#state === "awaiting_hello") {
      throw new ProtocolError("input ended before start");
    }
    if (this.#state === "attested") {
      throw new ProtocolError("input ended before start");
    }
    if (this.#state === "running") {
      this.#finishFailed("cancelled", { abort: true });
    }
  }

  handleOutputFailure() {
    if (this.#state !== "running") {
      return false;
    }
    this.#finish(
      {
        version: PROTOCOL_VERSION,
        type: "failed",
        request_id: this.#requestID,
        code: "invalid_response",
      },
      { abort: true, emit: false },
    );
    return true;
  }

  #attest(command) {
    // Checkpoint A is deliberately mock-only. A future SDK adapter must inject
    // an independently verified codex_sdk identity instead of mutating this one.
    const ready = validateEvent({
      version: PROTOCOL_VERSION,
      type: "ready",
      request_id: command.request_id,
      runtime: this.#runtimeIdentity,
    });
    this.#requestID = command.request_id;
    this.#state = "attested";
    this.#emit(ready);
  }

  #start(command) {
    this.#state = "running";
    this.#abortController = new AbortController();

    this.#emitValidated({
      version: PROTOCOL_VERSION,
      type: "started",
      request_id: this.#requestID,
    });

    this.#timeout = setTimeout(() => {
      if (this.#state === "running") {
        this.#finishFailed("timed_out", { abort: true });
      }
    }, command.budget.timeout_seconds * 1_000);

    Promise.resolve()
      .then(async () => {
        if (this.#state !== "running") {
          return;
        }
        // Keep transport IDs, instruction/schema IDs, counts, and budgets out
        // of the provider boundary. The future adapter may receive only the
        // exact confirmed model, prompt, and response-schema text.
        const providerInput = Object.freeze({
          model_id: command.model_id,
          application_prompt: command.application_prompt,
          application_response_schema: command.application_response_schema,
        });
        const completion = await this.#execute(providerInput, {
          signal: this.#abortController.signal,
        });
        if (this.#state !== "running") {
          return;
        }
        const validated = requireCompletionShape(completion, command.budget);
        this.#finish({
          version: PROTOCOL_VERSION,
          type: "completed",
          request_id: this.#requestID,
          structured_output: validated.structured_output,
          usage: validated.usage,
        });
      })
      .catch((error) => {
        if (this.#state !== "running") {
          return;
        }
        // Only an adapter that observed a no-terminal process exit may choose
        // provider_unavailable. Unknown internal failures fail closed as an
        // invalid response and never expose raw error text.
        const code = error instanceof SidecarFailure ? error.code : "invalid_response";
        this.#finishFailed(code, { abort: true });
      });
  }

  #finishFailed(code, { abort }) {
    this.#finish(
      {
        version: PROTOCOL_VERSION,
        type: "failed",
        request_id: this.#requestID,
        code,
      },
      { abort },
    );
  }

  #finish(event, { abort = false, emit = true } = {}) {
    if (this.#state !== "running") {
      return;
    }
    const validated = validateEvent(event);
    // Claim the terminal only after proving that the complete outer JSONL
    // frame fits and is encodable. Raw UTF-8 limits alone do not account for
    // JSON escaping expansion (for example, control characters).
    encodeEventFrame(validated);
    this.#state = "terminal";
    if (this.#timeout !== null) {
      clearTimeout(this.#timeout);
      this.#timeout = null;
    }
    if (abort) {
      this.#abortController.abort();
    }
    try {
      if (emit) {
        this.#emit(validated);
      }
    } finally {
      this.#resolveTerminal(validated);
    }
  }

  #emitValidated(event) {
    this.#emit(validateEvent(event));
  }
}
