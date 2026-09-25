export interface ProjectRef {
  path: string;
  name: string;
  lastOpenedAt?: string | number;
}

export type EncodedEnum = string | Record<string, unknown>;

export interface PresenceReading {
  presence: string;
  confidence?: string;
  observedAt?: string | number;
}

export interface LoopNode {
  id: string;
  title: string;
  loopType?: string;
  state: EncodedEnum;
  backend?: string;
  activity?: string;
  presence?: PresenceReading;
  pilotState?: string;
  sessionRestarts?: number;
  createdAt?: string | number;
  subGraph?: LoopGraph;
  [field: string]: unknown;
}

export interface LoopEdge {
  id?: string;
  from: string;
  to: string;
  kind?: string;
  condition?: EncodedEnum;
  payloadTransform?: EncodedEnum;
  fireCount?: number;
  [field: string]: unknown;
}

export interface LoopGraph {
  id: string;
  project: ProjectRef;
  nodes: LoopNode[];
  edges: LoopEdge[];
  revision?: number;
  [field: string]: unknown;
}

export interface NodesChanged {
  projectPath: string;
  revision: number;
  nodes: LoopNode[];
}

export type DaemonEvent =
  | { type: "recentProjectsListed"; projects: ProjectRef[] }
  | { type: "graphChanged"; graph: LoopGraph }
  | { type: "nodesChanged"; change: NodesChanged }
  | { type: "errorOccurred"; message: string }
  | { type: "unsupported"; name: string; payload: unknown };

export interface DaemonWireError {
  code: string;
  message: string;
}

export interface DaemonHelloEnvelope {
  version: 2;
  kind: "hello";
  supportedVersions: number[];
  selectedVersion?: number;
  clientID?: string;
  resumeFrom?: number;
  subscription?: { projectPaths?: string[] };
}

export interface DaemonRequestEnvelope {
  version: 2;
  kind: "request";
  requestID: string;
  command: Record<string, unknown>;
}

export interface DaemonResponseEnvelope {
  version: 2;
  kind: "response";
  requestID: string;
  event?: DaemonEvent;
  success?: true;
}

export interface DaemonEventEnvelope {
  version: 2;
  kind: "event";
  sequence: number;
  event: DaemonEvent;
}

export interface DaemonErrorEnvelope {
  version: 2;
  kind: "error";
  requestID?: string;
  error: DaemonWireError;
}

export type DaemonWireEnvelope =
  | DaemonHelloEnvelope
  | DaemonRequestEnvelope
  | DaemonResponseEnvelope
  | DaemonEventEnvelope
  | DaemonErrorEnvelope;
