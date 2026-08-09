import { pathToFileURL } from "node:url";

import {
  JSONLineFramer,
  MAXIMUM_PROCESS_BYTES,
  ProtocolError,
  encodeEventFrame,
  parseCommandFrame,
} from "./protocol.mjs";
import { CodexSidecarSession, SidecarFailure } from "./session.mjs";

async function unavailableExecutor() {
  throw new SidecarFailure("provider_unavailable");
}

export const mockRuntimeIdentity = Object.freeze({
  // Null artifact identities make this impossible to mistake for an audited
  // SDK/CLI runtime. No package dependency or provider communication exists.
  mode: "mock",
  sidecar_version: "0.0.0-private",
  sidecar_bundle_sha256: null,
  node_version: process.versions.node,
  node_sha256: null,
  architecture: process.arch,
  sdk_version: null,
  sdk_integrity: null,
  cli_version: null,
  cli_sha256: null,
});

export async function run({
  input = process.stdin,
  output = process.stdout,
  execute = unavailableExecutor,
  runtimeIdentity = mockRuntimeIdentity,
} = {}) {
  const framer = new JSONLineFramer();
  let exitCode = 0;
  let settled = false;
  let settle;
  let inputBytes = 0;
  let outputBytes = 0;
  const finished = new Promise((resolve) => {
    settle = resolve;
  });
  const session = new CodexSidecarSession({
    execute,
    runtimeIdentity,
    emit(event) {
      const frame = encodeEventFrame(event);
      outputBytes += frame.length;
      if (outputBytes > MAXIMUM_PROCESS_BYTES) {
        throw new ProtocolError("stdout exceeds the process byte limit");
      }
      output.write(frame);
    },
  });

  const cleanup = () => {
    input.off("data", onData);
    input.off("end", onEnd);
    input.off("error", onInputError);
    input.pause?.();
  };

  const finish = (code) => {
    if (settled) {
      return;
    }
    settled = true;
    exitCode = code;
    cleanup();
    settle();
  };

  const protocolFailure = () => {
    session.handleProtocolFailure();
    finish(2);
  };

  const onData = (chunk) => {
    if (settled) {
      return;
    }
    try {
      inputBytes += chunk.byteLength;
      if (inputBytes > MAXIMUM_PROCESS_BYTES) {
        throw new ProtocolError("stdin exceeds the process byte limit");
      }
      const frames = framer.push(chunk);
      for (const frame of frames) {
        if (settled) {
          break;
        }
        session.handleCommand(parseCommandFrame(frame));
      }
    } catch (error) {
      if (error instanceof ProtocolError) {
        protocolFailure();
        return;
      }
      finish(1);
    }
  };

  const onEnd = () => {
    try {
      framer.finish();
      if (!session.hasAcceptedRequest) {
        throw new ProtocolError("start command was not received");
      }
      session.handleInputEOF();
    } catch (error) {
      if (error instanceof ProtocolError) {
        protocolFailure();
        return;
      }
      finish(1);
    }
  };

  const onInputError = () => {
    try {
      session.handleInputEOF();
    } catch {
      // There is no accepted start, so no request failure frame is permitted.
    }
    finish(1);
  };

  const onOutputError = () => {
    // A broken parent pipe cannot receive a terminal frame. Swallow the stream
    // error, cancel upstream without another write, and never expose a stack or
    // protocol data to stderr.
    session.handleOutputFailure();
    finish(1);
  };

  input.on("data", onData);
  input.on("end", onEnd);
  input.on("error", onInputError);
  output.once("error", onOutputError);
  input.resume?.();

  session.waitForTerminal().then(() => finish(exitCode));
  await finished;
  return exitCode;
}

const invokedPath = process.argv[1];
if (invokedPath && import.meta.url === pathToFileURL(invokedPath).href) {
  process.exitCode = await run();
}
