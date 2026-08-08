import { Buffer } from "node:buffer";
import { TextDecoder } from "node:util";

export const PROTOCOL_VERSION = 1;
export const MAXIMUM_FRAME_BYTES = 262_144;
export const MAXIMUM_PROCESS_BYTES = 524_288;
export const MAXIMUM_JSON_DEPTH = 64;

export const FAILURE_CODES = Object.freeze([
  "cancelled",
  "timed_out",
  "authentication_required",
  "offline",
  "rate_limited",
  "quota_exceeded",
  "provider_unavailable",
  "refused",
  "invalid_response",
  "provider_mismatch",
]);

const failureCodeSet = new Set(FAILURE_CODES);
const canonicalUUIDPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const sha256Pattern = /^[0-9a-f]{64}$/;
const npmIntegrityPattern = /^sha512-[A-Za-z0-9+/]+={0,2}$/;
const modelIDPattern = /^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$/;
const applicationIDPattern = /^[a-z0-9][a-z0-9._-]{0,127}$/;
const utf8Decoder = new TextDecoder("utf-8", { fatal: true });

const startKeys = Object.freeze([
  "version",
  "type",
  "request_id",
  "provider_id",
  "model_id",
  "application_instruction_id",
  "application_prompt",
  "application_response_schema_id",
  "application_response_schema",
  "budget",
  "input_character_count",
  "input_utf8_byte_count",
]);
const cancelKeys = Object.freeze(["version", "type", "request_id"]);
const helloKeys = cancelKeys;
const budgetKeys = Object.freeze([
  "maximum_input_characters",
  "maximum_input_utf8_bytes",
  "maximum_output_characters",
  "maximum_output_utf8_bytes",
  "maximum_output_tokens",
  "maximum_warnings",
  "timeout_seconds",
]);
const startedKeys = cancelKeys;
const readyKeys = Object.freeze(["version", "type", "request_id", "runtime"]);
const runtimeKeys = Object.freeze([
  "mode",
  "sidecar_version",
  "sidecar_bundle_sha256",
  "node_version",
  "node_sha256",
  "architecture",
  "sdk_version",
  "sdk_integrity",
  "cli_version",
  "cli_sha256",
]);
const completedKeys = Object.freeze([
  "version",
  "type",
  "request_id",
  "structured_output",
  "usage",
]);
const failedKeys = Object.freeze(["version", "type", "request_id", "code"]);
const usageKeys = Object.freeze(["input_tokens", "output_tokens"]);

const absoluteBudgetMaximums = Object.freeze({
  maximum_input_characters: 20_000,
  maximum_input_utf8_bytes: 80_000,
  maximum_output_characters: 20_000,
  maximum_output_utf8_bytes: 80_000,
  maximum_output_tokens: 8_192,
  maximum_warnings: 20,
  timeout_seconds: 120,
});

export class ProtocolError extends Error {
  constructor(reason = "invalid protocol data") {
    super(reason);
    this.name = "ProtocolError";
  }
}

function isPlainObject(value) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    return false;
  }

  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function requirePlainObject(value, label) {
  if (!isPlainObject(value)) {
    throw new ProtocolError(`${label} must be an object`);
  }
}

function requireExactKeys(value, allowedKeys, label) {
  requirePlainObject(value, label);
  const actualKeys = Object.keys(value);
  if (actualKeys.length !== allowedKeys.length) {
    throw new ProtocolError(`${label} has an invalid field set`);
  }

  const allowed = new Set(allowedKeys);
  if (actualKeys.some((key) => !allowed.has(key))) {
    throw new ProtocolError(`${label} has an unknown field`);
  }
}

function requireString(value, label) {
  if (typeof value !== "string") {
    throw new ProtocolError(`${label} must be a string`);
  }
  for (let index = 0; index < value.length; index += 1) {
    const codeUnit = value.charCodeAt(index);
    if (codeUnit >= 0xd800 && codeUnit <= 0xdbff) {
      const trailing = value.charCodeAt(index + 1);
      if (!(trailing >= 0xdc00 && trailing <= 0xdfff)) {
        throw new ProtocolError(`${label} contains an unpaired UTF-16 surrogate`);
      }
      index += 1;
    } else if (codeUnit >= 0xdc00 && codeUnit <= 0xdfff) {
      throw new ProtocolError(`${label} contains an unpaired UTF-16 surrogate`);
    }
  }
  return value;
}

function requireBoundedVisibleASCII(value, label) {
  const string = requireString(value, label);
  if (!/^[\x21-\x7e]{1,256}$/.test(string)) {
    throw new ProtocolError(`${label} must be 1...256 bytes of visible ASCII`);
  }
  return string;
}

function requireNonWhitespaceString(value, label) {
  const string = requireString(value, label);
  if (![...string].some((scalar) => !isProtocolWhitespace(scalar.codePointAt(0)))) {
    throw new ProtocolError(`${label} must contain a non-whitespace character`);
  }
  return string;
}

function isProtocolWhitespace(codePoint) {
  return (
    (codePoint >= 0x0009 && codePoint <= 0x000d) ||
    codePoint === 0x0020 ||
    codePoint === 0x0085 ||
    codePoint === 0x00a0 ||
    codePoint === 0x1680 ||
    (codePoint >= 0x2000 && codePoint <= 0x200a) ||
    codePoint === 0x2028 ||
    codePoint === 0x2029 ||
    codePoint === 0x202f ||
    codePoint === 0x205f ||
    codePoint === 0x3000 ||
    codePoint === 0xfeff
  );
}

function requirePattern(value, pattern, label) {
  const string = requireString(value, label);
  if (!pattern.test(string)) {
    throw new ProtocolError(`${label} has an invalid format`);
  }
  return string;
}

function requireCanonicalRequestID(value) {
  if (typeof value !== "string" || !canonicalUUIDPattern.test(value)) {
    throw new ProtocolError("request_id must be a canonical lowercase UUID");
  }
  return value;
}

function requireInteger(value, label, { positive = false } = {}) {
  if (
    !Number.isSafeInteger(value) ||
    Object.is(value, -0) ||
    (positive ? value <= 0 : value < 0)
  ) {
    const qualifier = positive ? "a positive" : "a nonnegative";
    throw new ProtocolError(`${label} must be ${qualifier} integer`);
  }
  return value;
}

function validateVersionAndRequestID(value) {
  if (value.version !== PROTOCOL_VERSION) {
    throw new ProtocolError("unknown protocol version");
  }
  requireCanonicalRequestID(value.request_id);
}

function validateBudget(candidate) {
  requireExactKeys(candidate, budgetKeys, "budget");

  for (const key of budgetKeys) {
    const actual = requireInteger(candidate[key], `budget.${key}`, { positive: true });
    if (actual > absoluteBudgetMaximums[key]) {
      throw new ProtocolError(`budget.${key} exceeds the absolute maximum`);
    }
  }

  return Object.freeze({ ...candidate });
}

function validateStart(candidate) {
  requireExactKeys(candidate, startKeys, "start command");
  validateVersionAndRequestID(candidate);
  if (candidate.type !== "start") {
    throw new ProtocolError("invalid start command type");
  }
  if (candidate.provider_id !== "codex") {
    throw new ProtocolError("unknown provider_id");
  }

  const modelID = requirePattern(candidate.model_id, modelIDPattern, "model_id");
  const instructionID = requirePattern(
    candidate.application_instruction_id,
    applicationIDPattern,
    "application_instruction_id",
  );
  const prompt = requireNonWhitespaceString(candidate.application_prompt, "application_prompt");
  const schemaID = requirePattern(
    candidate.application_response_schema_id,
    applicationIDPattern,
    "application_response_schema_id",
  );
  const schema = requireNonWhitespaceString(
    candidate.application_response_schema,
    "application_response_schema",
  );
  const budget = validateBudget(candidate.budget);
  const characterCount = requireInteger(candidate.input_character_count, "input_character_count");
  const utf8ByteCount = requireInteger(candidate.input_utf8_byte_count, "input_utf8_byte_count");

  const measuredUTF8Bytes = Buffer.byteLength(prompt, "utf8") + Buffer.byteLength(schema, "utf8");
  if (utf8ByteCount !== measuredUTF8Bytes) {
    throw new ProtocolError("input UTF-8 byte count does not match the application payload");
  }
  if (
    characterCount > budget.maximum_input_characters ||
    utf8ByteCount > budget.maximum_input_utf8_bytes
  ) {
    throw new ProtocolError("application payload exceeds the confirmed input budget");
  }

  return Object.freeze({
    version: PROTOCOL_VERSION,
    type: "start",
    request_id: candidate.request_id,
    provider_id: "codex",
    model_id: modelID,
    application_instruction_id: instructionID,
    application_prompt: prompt,
    application_response_schema_id: schemaID,
    application_response_schema: schema,
    budget,
    input_character_count: characterCount,
    input_utf8_byte_count: utf8ByteCount,
  });
}

function validateCancel(candidate) {
  requireExactKeys(candidate, cancelKeys, "cancel command");
  validateVersionAndRequestID(candidate);
  if (candidate.type !== "cancel") {
    throw new ProtocolError("invalid cancel command type");
  }

  return Object.freeze({
    version: PROTOCOL_VERSION,
    type: "cancel",
    request_id: candidate.request_id,
  });
}

function validateHello(candidate) {
  requireExactKeys(candidate, helloKeys, "hello command");
  validateVersionAndRequestID(candidate);
  if (candidate.type !== "hello") {
    throw new ProtocolError("invalid hello command type");
  }

  return Object.freeze({
    version: PROTOCOL_VERSION,
    type: "hello",
    request_id: candidate.request_id,
  });
}

export function validateCommand(candidate) {
  requirePlainObject(candidate, "command");
  if (candidate.type === "hello") {
    return validateHello(candidate);
  }
  if (candidate.type === "start") {
    return validateStart(candidate);
  }
  if (candidate.type === "cancel") {
    return validateCancel(candidate);
  }
  throw new ProtocolError("unknown command type");
}

function requireNullableBoundedVisibleASCII(value, label) {
  return value === null ? null : requireBoundedVisibleASCII(value, label);
}

function requireNullableSHA256(value, label) {
  if (value === null) {
    return null;
  }
  if (typeof value !== "string" || !sha256Pattern.test(value)) {
    throw new ProtocolError(`${label} must be a lowercase SHA-256 digest`);
  }
  return value;
}

function isCanonicalSHA512SRI(value) {
  if (!npmIntegrityPattern.test(value)) {
    return false;
  }
  const encodedDigest = value.slice("sha512-".length);
  const decodedDigest = Buffer.from(encodedDigest, "base64");
  return (
    decodedDigest.length === 64 && decodedDigest.toString("base64") === encodedDigest
  );
}

function validateRuntime(candidate) {
  requireExactKeys(candidate, runtimeKeys, "runtime");
  if (candidate.mode !== "mock" && candidate.mode !== "codex_sdk") {
    throw new ProtocolError("unknown runtime mode");
  }
  if (candidate.architecture !== "arm64" && candidate.architecture !== "x64") {
    throw new ProtocolError("unknown runtime architecture");
  }

  const runtime = {
    mode: candidate.mode,
    sidecar_version: requireBoundedVisibleASCII(
      candidate.sidecar_version,
      "runtime.sidecar_version",
    ),
    sidecar_bundle_sha256: requireNullableSHA256(
      candidate.sidecar_bundle_sha256,
      "runtime.sidecar_bundle_sha256",
    ),
    node_version: requireBoundedVisibleASCII(candidate.node_version, "runtime.node_version"),
    node_sha256: requireNullableSHA256(candidate.node_sha256, "runtime.node_sha256"),
    architecture: candidate.architecture,
    sdk_version: requireNullableBoundedVisibleASCII(
      candidate.sdk_version,
      "runtime.sdk_version",
    ),
    sdk_integrity: requireNullableBoundedVisibleASCII(
      candidate.sdk_integrity,
      "runtime.sdk_integrity",
    ),
    cli_version: requireNullableBoundedVisibleASCII(
      candidate.cli_version,
      "runtime.cli_version",
    ),
    cli_sha256: requireNullableSHA256(candidate.cli_sha256, "runtime.cli_sha256"),
  };

  const providerIdentity = [
    runtime.sidecar_bundle_sha256,
    runtime.node_sha256,
    runtime.sdk_version,
    runtime.sdk_integrity,
    runtime.cli_version,
    runtime.cli_sha256,
  ];
  if (runtime.mode === "mock" && providerIdentity.some((value) => value !== null)) {
    throw new ProtocolError("mock runtime identity must not claim SDK artifacts");
  }
  if (
    runtime.mode === "codex_sdk" &&
    providerIdentity.some((value) => typeof value !== "string" || value.length === 0)
  ) {
    throw new ProtocolError("Codex SDK runtime identity must be complete");
  }
  if (runtime.mode === "codex_sdk" && !isCanonicalSHA512SRI(runtime.sdk_integrity)) {
    throw new ProtocolError("Codex SDK integrity must be an npm SHA-512 SRI string");
  }

  return Object.freeze(runtime);
}

function validateUsage(candidate) {
  requireExactKeys(candidate, usageKeys, "usage");
  const inputTokens =
    candidate.input_tokens === null
      ? null
      : requireInteger(candidate.input_tokens, "usage.input_tokens");
  const outputTokens = requireInteger(candidate.output_tokens, "usage.output_tokens");
  return Object.freeze({ input_tokens: inputTokens, output_tokens: outputTokens });
}

export function validateEvent(candidate) {
  requirePlainObject(candidate, "event");

  if (candidate.type === "ready") {
    requireExactKeys(candidate, readyKeys, "ready event");
    validateVersionAndRequestID(candidate);
    return Object.freeze({
      version: PROTOCOL_VERSION,
      type: "ready",
      request_id: candidate.request_id,
      runtime: validateRuntime(candidate.runtime),
    });
  }

  if (candidate.type === "started") {
    requireExactKeys(candidate, startedKeys, "started event");
    validateVersionAndRequestID(candidate);
    return Object.freeze({
      version: PROTOCOL_VERSION,
      type: "started",
      request_id: candidate.request_id,
    });
  }

  if (candidate.type === "completed") {
    requireExactKeys(candidate, completedKeys, "completed event");
    validateVersionAndRequestID(candidate);
    return Object.freeze({
      version: PROTOCOL_VERSION,
      type: "completed",
      request_id: candidate.request_id,
      structured_output: requireString(candidate.structured_output, "structured_output"),
      usage: validateUsage(candidate.usage),
    });
  }

  if (candidate.type === "failed") {
    requireExactKeys(candidate, failedKeys, "failed event");
    validateVersionAndRequestID(candidate);
    if (!failureCodeSet.has(candidate.code)) {
      throw new ProtocolError("unknown failure code");
    }
    return Object.freeze({
      version: PROTOCOL_VERSION,
      type: "failed",
      request_id: candidate.request_id,
      code: candidate.code,
    });
  }

  throw new ProtocolError("unknown event type");
}

function frameBytes(frame) {
  if (typeof frame === "string") {
    return Buffer.from(frame, "utf8");
  }
  if (frame instanceof Uint8Array) {
    return Buffer.from(frame.buffer, frame.byteOffset, frame.byteLength);
  }
  throw new ProtocolError("frame must be UTF-8 bytes");
}

export function decodeFrame(frame) {
  const bytes = frameBytes(frame);
  if (bytes.length === 0) {
    throw new ProtocolError("empty protocol frame");
  }
  if (bytes.length > MAXIMUM_FRAME_BYTES) {
    throw new ProtocolError("protocol frame exceeds the byte limit");
  }
  if (bytes.includes(0x0a) || bytes.includes(0x0d)) {
    throw new ProtocolError("protocol frame contains an invalid line ending");
  }
  if (bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) {
    throw new ProtocolError("protocol frame must not contain a UTF-8 BOM");
  }

  let text;
  try {
    text = utf8Decoder.decode(bytes);
  } catch {
    throw new ProtocolError("protocol frame is not valid UTF-8");
  }

  try {
    preflightJSON(text);
    return JSON.parse(text);
  } catch {
    throw new ProtocolError("protocol frame is not valid JSON");
  }
}

function preflightJSON(text) {
  let index = 0;

  const fail = () => {
    throw new ProtocolError("protocol frame is not canonical JSON");
  };

  const skipWhitespace = () => {
    while (text[index] === " " || text[index] === "\t") {
      index += 1;
    }
  };

  const parseString = () => {
    const start = index;
    if (text[index] !== '"') {
      fail();
    }
    index += 1;
    while (index < text.length) {
      const character = text[index];
      if (character === '"') {
        index += 1;
        try {
          const decoded = JSON.parse(text.slice(start, index));
          for (let offset = 0; offset < decoded.length; offset += 1) {
            const codeUnit = decoded.charCodeAt(offset);
            if (codeUnit >= 0xd800 && codeUnit <= 0xdbff) {
              const next = decoded.charCodeAt(offset + 1);
              if (!(next >= 0xdc00 && next <= 0xdfff)) {
                fail();
              }
              offset += 1;
            } else if (codeUnit >= 0xdc00 && codeUnit <= 0xdfff) {
              fail();
            }
          }
          return decoded;
        } catch {
          fail();
        }
      }
      if (character === "\\") {
        index += 1;
        if (index >= text.length) {
          fail();
        }
        if (text[index] === "u") {
          const digits = text.slice(index + 1, index + 5);
          if (!/^[0-9a-fA-F]{4}$/.test(digits)) {
            fail();
          }
          index += 5;
          continue;
        }
        if (!'"\\/bfnrt'.includes(text[index])) {
          fail();
        }
        index += 1;
        continue;
      }
      if (character.charCodeAt(0) <= 0x1f) {
        fail();
      }
      index += 1;
    }
    fail();
  };

  const parseInteger = () => {
    const start = index;
    if (text[index] === "-") {
      index += 1;
    }
    if (text[index] === "0") {
      index += 1;
      if (text[index] >= "0" && text[index] <= "9") {
        fail();
      }
    } else if (text[index] >= "1" && text[index] <= "9") {
      index += 1;
      while (text[index] >= "0" && text[index] <= "9") {
        index += 1;
      }
    } else {
      fail();
    }
    const following = text[index];
    if (following === "." || following === "e" || following === "E") {
      fail();
    }
    const token = text.slice(start, index);
    const number = Number(token);
    if (!Number.isSafeInteger(number) || Object.is(number, -0)) {
      fail();
    }
  };

  const parseLiteral = (literal) => {
    if (!text.startsWith(literal, index)) {
      fail();
    }
    index += literal.length;
  };

  const parseValue = (depth = 0) => {
    skipWhitespace();
    const character = text[index];
    if (character === "{") {
      if (depth >= MAXIMUM_JSON_DEPTH) {
        fail();
      }
      parseObject(depth + 1);
      return;
    }
    if (character === "[") {
      if (depth >= MAXIMUM_JSON_DEPTH) {
        fail();
      }
      parseArray(depth + 1);
      return;
    }
    if (character === '"') {
      parseString();
      return;
    }
    if (character === "t") {
      parseLiteral("true");
      return;
    }
    if (character === "f") {
      parseLiteral("false");
      return;
    }
    if (character === "n") {
      parseLiteral("null");
      return;
    }
    parseInteger();
  };

  const parseObject = (depth) => {
    index += 1;
    skipWhitespace();
    const keys = new Set();
    if (text[index] === "}") {
      index += 1;
      return;
    }
    while (index < text.length) {
      const key = parseString();
      if (keys.has(key)) {
        fail();
      }
      keys.add(key);
      skipWhitespace();
      if (text[index] !== ":") {
        fail();
      }
      index += 1;
      parseValue(depth);
      skipWhitespace();
      if (text[index] === "}") {
        index += 1;
        return;
      }
      if (text[index] !== ",") {
        fail();
      }
      index += 1;
      skipWhitespace();
    }
    fail();
  };

  const parseArray = (depth) => {
    index += 1;
    skipWhitespace();
    if (text[index] === "]") {
      index += 1;
      return;
    }
    while (index < text.length) {
      parseValue(depth);
      skipWhitespace();
      if (text[index] === "]") {
        index += 1;
        return;
      }
      if (text[index] !== ",") {
        fail();
      }
      index += 1;
      skipWhitespace();
    }
    fail();
  };

  parseValue();
  skipWhitespace();
  if (index !== text.length) {
    fail();
  }
}

export function parseCommandFrame(frame) {
  return validateCommand(decodeFrame(frame));
}

export function parseEventFrame(frame) {
  return validateEvent(decodeFrame(frame));
}

export function encodeEventFrame(event) {
  const validated = validateEvent(event);
  const payload = Buffer.from(JSON.stringify(validated), "utf8");
  // Validate generated JSON too, so an internal lone surrogate or other
  // noncanonical value can never escape as a frame the peer must reject.
  decodeFrame(payload);
  if (payload.length > MAXIMUM_FRAME_BYTES) {
    throw new ProtocolError("protocol event exceeds the byte limit");
  }
  return Buffer.concat([payload, Buffer.of(0x0a)], payload.length + 1);
}

export class JSONLineFramer {
  #pending = Buffer.allocUnsafe(MAXIMUM_FRAME_BYTES);
  #pendingLength = 0;
  #closed = false;

  push(chunk) {
    if (this.#closed) {
      throw new ProtocolError("framer is closed");
    }
    if (!(chunk instanceof Uint8Array)) {
      throw new ProtocolError("input chunk must contain bytes");
    }

    const bytes = Buffer.from(chunk.buffer, chunk.byteOffset, chunk.byteLength);
    const frames = [];
    let offset = 0;

    while (offset < bytes.length) {
      const lineFeedIndex = bytes.indexOf(0x0a, offset);
      if (lineFeedIndex === -1) {
        this.#append(bytes.subarray(offset));
        break;
      }

      const segment = bytes.subarray(offset, lineFeedIndex);
      if (this.#pendingLength + segment.length > MAXIMUM_FRAME_BYTES) {
        this.#closed = true;
        this.#clearPending();
        throw new ProtocolError("protocol frame exceeds the byte limit");
      }
      const frame = this.#takeFrame(segment);
      frames.push(frame);
      offset = lineFeedIndex + 1;
    }

    return frames;
  }

  finish() {
    if (this.#closed) {
      throw new ProtocolError("framer is closed");
    }
    this.#closed = true;
    if (this.#pendingLength !== 0) {
      this.#clearPending();
      throw new ProtocolError("unterminated protocol frame");
    }
  }

  #append(segment) {
    if (this.#pendingLength + segment.length > MAXIMUM_FRAME_BYTES) {
      this.#closed = true;
      this.#clearPending();
      throw new ProtocolError("protocol frame exceeds the byte limit");
    }
    if (segment.length === 0) {
      return;
    }
    segment.copy(this.#pending, this.#pendingLength);
    this.#pendingLength += segment.length;
  }

  #takeFrame(finalSegment) {
    if (this.#pendingLength === 0) {
      return Buffer.from(finalSegment);
    }

    const totalLength = this.#pendingLength + finalSegment.length;
    const frame = Buffer.allocUnsafe(totalLength);
    this.#pending.copy(frame, 0, 0, this.#pendingLength);
    finalSegment.copy(frame, this.#pendingLength);
    this.#clearPending();
    return frame;
  }

  #clearPending() {
    this.#pending.fill(0, 0, this.#pendingLength);
    this.#pendingLength = 0;
  }
}
