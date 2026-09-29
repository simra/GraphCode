export type ProjectLocationKind = "local" | "ssh" | "codespace";

export interface ProjectCapabilities {
  revealInFileManager: boolean;
  templates: boolean;
  attachments: boolean;
  interactiveTerminals: boolean;
  diagnostics: boolean;
  memoryReads?: boolean;
}

export interface ProjectMetadata {
  location: ProjectLocationKind;
  capabilities: ProjectCapabilities;
}

export interface ProjectRef {
  path: string;
  name: string;
  lastOpenedAt?: string | number;
  metadata?: ProjectMetadata;
}

export type EncodedEnum = string | Record<string, unknown>;

export interface PresenceReading {
  presence: string;
  confidence?: string;
  observedAt?: string | number;
  exitCode?: number;
}

export interface QuickChatActivity {
  sequence: number;
  text?: string;
  presence?: PresenceReading;
}

export interface QuickChat {
  id: string;
  title: string;
  backend: string;
  createdAt: string | number;
  activity?: QuickChatActivity;
}

export interface GoalSpec {
  summary: string;
  predicate?: string;
  pollIntervalSeconds: number;
  stallAfterSeconds?: number;
  metricCommand?: string;
  metricDirection: "minimize" | "maximize";
  tokenBudget?: number;
  skipsUnchangedWorkspace: boolean;
}

export interface UsageSample {
  inputTokens?: number;
  outputTokens?: number;
  costUSD?: number;
  reportedAt?: string | number;
}

export interface WorktreeRef {
  id: string;
  repositoryPath: string;
  worktreePath: string;
  branch: string;
}

export interface PromptAttachment {
  id: string;
  path: string;
}

export interface MetricSample {
  value: number;
  recordedAt: string | number;
}

export interface TemplateFollow {
  id: string;
  name: string;
  missing: boolean;
}

export interface MailroomDigest {
  count: number;
  latestID: number;
  fingerprint: number;
}

export interface MailroomPost {
  id: number;
  at: string | number;
  authorID?: string;
  author: string;
  topic?: string;
  body: string;
  kind: "notice" | "letter";
}

export interface Mailbox {
  posts: MailroomPost[];
  bodiesTrimmed: boolean;
  digest: MailroomDigest;
  lastRead?: number;
  highestDeliveredID?: number;
  remaining: number;
  prunedUnread: number;
}

export interface MailroomWatch {
  topic?: string;
}

export type BeatKind =
  "reading" | "editing" | "running" | "thinking" | "found" | "asking" | "done";

export interface SummaryBeat {
  id: string;
  at: string | number;
  pass: number;
  kind: BeatKind;
  text: string;
  evidence?: string;
  endsTurn: boolean;
}

export interface PassSummary {
  pass: number;
  text: string;
  delta?: string;
}

export interface LoopSummary {
  beats: SummaryBeat[];
  passes: PassSummary[];
  currentPass: number;
  lastTurnAt?: string | number;
}

export interface BoardNode {
  id: string;
  text: string;
  shape: "box" | "rounded" | "decision" | "terminal";
}

export interface BoardEdge {
  from: string;
  to: string;
  label?: string;
  style: "solid" | "dashed" | "thick";
}

export interface BoardTable {
  headers: string[];
  rows: string[][];
  alignments: ("unspecified" | "leading" | "center" | "trailing")[];
}

export interface SummaryBoard {
  form: "flow" | "table";
  title?: string;
  direction: "topDown" | "leftRight";
  nodes: BoardNode[];
  edges: BoardEdge[];
  table?: BoardTable;
  pass: number;
  composedAt?: string | number;
  source: string;
}

export interface LoopNode {
  id: string;
  title: string;
  loopType?: string;
  state: EncodedEnum;
  checkDescription?: string;
  triggerPrompt?: string;
  heartbeatIntervalSeconds?: number;
  firstInstruction?: string;
  pausesBeforeWritesOnly?: boolean;
  attachments?: PromptAttachment[];
  goal?: GoalSpec;
  backend?: string;
  modelTier?: string;
  worktreeBinding?: WorktreeRef;
  activity?: string;
  summary?: LoopSummary;
  board?: SummaryBoard;
  presence?: PresenceReading;
  hasActiveDependents?: boolean;
  metricHistory?: MetricSample[];
  createdBy?: string;
  createdFromTemplateID?: string;
  templateFollow?: TemplateFollow;
  lastMailroomRead?: number;
  mailroomWatch?: MailroomWatch;
  stallReason?: string;
  launchFailure?: EncodedEnum;
  resolution?: EncodedEnum;
  pendingCompletion?: EncodedEnum;
  goalSetAt?: string | number;
  pilotState?: EncodedEnum;
  usage?: UsageSample;
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
  cycleGuard?: {
    maxIterations?: number;
    until?: string;
    stopAfterPassesWithoutImprovement?: number;
  };
  spawnTargetProjectPath?: string;
  fireCount?: number;
  [field: string]: unknown;
}

export interface LoopGraph {
  id: string;
  project: ProjectRef;
  nodes: LoopNode[];
  edges: LoopEdge[];
  mailroomDigest?: MailroomDigest;
  revision?: number;
  [field: string]: unknown;
}

export interface NodesChanged {
  projectPath: string;
  revision: number;
  nodes: LoopNode[];
}

export type SettingsApplicationTiming =
  "live" | "nextLoop" | "nextSession" | "appRestart" | "daemonRestart";

// Must match GraphcodeSettingsContract.maximumResolvedSessionGraceMinutes.
export const MAX_RESOLVED_SESSION_GRACE_MINUTES = 150_119_987_579_016;

export interface SettingsSnapshot {
  settings: Record<string, unknown>;
  revision: string;
  exists: boolean;
  supportDirectory: string;
  filePath: string;
  fields: {
    field: string;
    timing: SettingsApplicationTiming;
  }[];
}

export type TranscriptEntryKind =
  "prompt" | "assistant" | "toolUse" | "toolResult" | "status";

export type TranscriptRedaction =
  | "prompt"
  | "toolInput"
  | "toolResult"
  | "filesystemPath"
  | "secret"
  | "modelMetadata";

export interface TranscriptEntry {
  sourceOffset: number;
  timestamp?: string;
  kind: TranscriptEntryKind;
  text: string;
  toolName?: string;
  redactions: TranscriptRedaction[];
}

export interface TranscriptPage {
  nodeID: string;
  provider: "claudeCode" | "copilotCLI" | "codex" | "openCode" | "pi";
  entries: TranscriptEntry[];
  nextCursor?: string;
  hasMore: boolean;
}

export type NodeResourceKind =
  "memory" | "playbookCurrent" | "playbookHistory" | string;

export type NodeResourceEntryKind = "memory" | "refinement" | "rollback";

export type NodeResourceRedaction = "filesystemPath" | "secret";

export interface NodeResourceEntry {
  sequence: number;
  timestamp: string;
  kind: NodeResourceEntryKind;
  content: string;
  redactions: NodeResourceRedaction[];
  rollbackAvailable?: boolean;
}

export interface CurrentPlaybookState {
  content?: string;
  redactions: NodeResourceRedaction[];
  rollbackAvailable: boolean;
}

export interface NodeResourcePage {
  nodeID: string;
  resource: NodeResourceKind;
  entries: NodeResourceEntry[];
  currentPlaybook?: CurrentPlaybookState;
  nextCursor?: string;
  hasMore: boolean;
}

export type DaemonEvent =
  | { type: "recentProjectsListed"; projects: ProjectRef[] }
  | { type: "graphChanged"; graph: LoopGraph }
  | { type: "nodesChanged"; change: NodesChanged }
  | { type: "quickChatsListed"; chats: QuickChat[] }
  | { type: "quickChatChanged"; chat: QuickChat }
  | { type: "quickChatDeleted"; id: string }
  | { type: "quickChatActivity"; id: string; activity: QuickChatActivity }
  | { type: "mailbox"; projectPath: string; mailbox: Mailbox }
  | { type: "settingsChanged"; snapshot: SettingsSnapshot }
  | { type: "transcriptPage"; page: TranscriptPage }
  | { type: "nodeResourcePage"; page: NodeResourcePage }
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
