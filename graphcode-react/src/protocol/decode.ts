import { z } from "zod";
import type {
  DaemonEvent,
  DaemonWireEnvelope,
  LoopGraph,
  LoopNode,
} from "./domain";

const uuidLike = z.string().min(1);
const encodedEnum = z.union([z.string(), z.record(z.string(), z.unknown())]);

const projectRefSchema = z
  .object({
    path: z.string().min(1),
    name: z.string().min(1),
    lastOpenedAt: z.union([z.string(), z.number()]).optional(),
  })
  .passthrough();

const presenceSchema = z
  .object({
    presence: z.string().min(1),
    confidence: z.string().optional(),
    observedAt: z.union([z.string(), z.number()]).optional(),
  })
  .passthrough();

const loopNodeSchema: z.ZodType<LoopNode> = z.lazy(() =>
  z
    .object({
      id: uuidLike,
      title: z.string(),
      loopType: z.string().optional(),
      state: encodedEnum.default("idle"),
      backend: z.string().optional(),
      activity: z.string().optional(),
      presence: presenceSchema.optional(),
      pilotState: z.string().optional(),
      sessionRestarts: z.number().int().nonnegative().optional(),
      createdAt: z.union([z.string(), z.number()]).optional(),
      subGraph: loopGraphSchema.optional(),
    })
    .passthrough(),
);

const loopEdgeSchema = z
  .object({
    id: uuidLike.optional(),
    from: uuidLike,
    to: uuidLike,
    kind: z.string().optional(),
    condition: encodedEnum.optional(),
    payloadTransform: encodedEnum.optional(),
    fireCount: z.number().int().nonnegative().optional(),
  })
  .passthrough();

const loopGraphSchema: z.ZodType<LoopGraph> = z.lazy(() =>
  z
    .object({
      id: uuidLike,
      project: projectRefSchema,
      nodes: z.array(loopNodeSchema).default([]),
      edges: z.array(loopEdgeSchema).default([]),
      revision: z.number().int().nonnegative().optional(),
    })
    .passthrough(),
);

const nodesChangedSchema = z.object({
  projectPath: z.string().min(1),
  revision: z.number().int().nonnegative(),
  nodes: z.array(loopNodeSchema),
});

const rawEnvelopeSchema = z
  .object({
    version: z.literal(2),
    kind: z.enum(["hello", "request", "response", "event", "error"]),
    supportedVersions: z.array(z.number().int()).optional(),
    selectedVersion: z.number().int().optional(),
    clientID: z.string().optional(),
    resumeFrom: z.number().int().nonnegative().optional(),
    subscription: z
      .object({ projectPaths: z.array(z.string().min(1)).optional() })
      .optional(),
    requestID: z.string().optional(),
    sequence: z.number().int().nonnegative().optional(),
    command: z.record(z.string(), z.unknown()).optional(),
    event: z.record(z.string(), z.unknown()).optional(),
    error: z
      .object({ code: z.string().min(1), message: z.string().min(1) })
      .optional(),
    success: z.boolean().optional(),
  })
  .strict();

export class ProtocolDecodeError extends Error {
  constructor(
    message: string,
    readonly causeValue?: unknown,
  ) {
    super(message);
    this.name = "ProtocolDecodeError";
  }
}

function singleAssociatedValue(payload: unknown): unknown {
  if (typeof payload === "object" && payload !== null && "_0" in payload) {
    return (payload as Record<string, unknown>)._0;
  }
  return payload;
}

function decodeEvent(raw: Record<string, unknown>): DaemonEvent {
  const entries = Object.entries(raw);
  if (entries.length !== 1) {
    throw new ProtocolDecodeError(
      "Daemon event must contain exactly one case",
      raw,
    );
  }

  const [name, payload] = entries[0];
  switch (name) {
    case "recentProjectsListed":
      return {
        type: name,
        projects: z
          .array(projectRefSchema)
          .parse(singleAssociatedValue(payload)),
      };
    case "graphChanged":
      return {
        type: name,
        graph: loopGraphSchema.parse(singleAssociatedValue(payload)),
      };
    case "nodesChanged":
      return { type: name, change: nodesChangedSchema.parse(payload) };
    case "errorOccurred":
      return {
        type: name,
        message: z.string().parse(singleAssociatedValue(payload)),
      };
    default:
      return { type: "unsupported", name, payload };
  }
}

export function decodeEnvelope(input: unknown): DaemonWireEnvelope {
  const parsed = rawEnvelopeSchema.safeParse(input);
  if (!parsed.success) {
    throw new ProtocolDecodeError(
      `Invalid daemon v2 envelope: ${z.prettifyError(parsed.error)}`,
      input,
    );
  }

  const envelope = parsed.data;
  switch (envelope.kind) {
    case "hello":
      if (!envelope.supportedVersions?.length) {
        throw new ProtocolDecodeError(
          "Hello envelope is missing supportedVersions",
          input,
        );
      }
      return {
        version: 2,
        kind: "hello",
        supportedVersions: envelope.supportedVersions,
        selectedVersion: envelope.selectedVersion,
        clientID: envelope.clientID,
        resumeFrom: envelope.resumeFrom,
        subscription: envelope.subscription,
      };
    case "request":
      if (!envelope.requestID || !envelope.command) {
        throw new ProtocolDecodeError(
          "Request envelope is missing requestID or command",
          input,
        );
      }
      return {
        version: 2,
        kind: "request",
        requestID: envelope.requestID,
        command: envelope.command,
      };
    case "response":
      if (
        !envelope.requestID ||
        (!envelope.event && envelope.success !== true)
      ) {
        throw new ProtocolDecodeError(
          "Response envelope requires requestID and event or success",
          input,
        );
      }
      return {
        version: 2,
        kind: "response",
        requestID: envelope.requestID,
        event: envelope.event ? decodeEvent(envelope.event) : undefined,
        success: envelope.success === true ? true : undefined,
      };
    case "event":
      if (envelope.sequence === undefined || !envelope.event) {
        throw new ProtocolDecodeError(
          "Event envelope is missing sequence or event",
          input,
        );
      }
      return {
        version: 2,
        kind: "event",
        sequence: envelope.sequence,
        event: decodeEvent(envelope.event),
      };
    case "error":
      if (!envelope.error) {
        throw new ProtocolDecodeError(
          "Error envelope is missing error details",
          input,
        );
      }
      return {
        version: 2,
        kind: "error",
        requestID: envelope.requestID,
        error: envelope.error,
      };
  }
}

export function daemonHello(
  clientID: string,
  resumeFrom?: number,
  projectPaths?: string[],
): DaemonWireEnvelope {
  return {
    version: 2,
    kind: "hello",
    supportedVersions: [1, 2],
    clientID,
    resumeFrom,
    subscription: projectPaths ? { projectPaths } : undefined,
  };
}
