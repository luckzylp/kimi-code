/**
 * ACP client connection bridge — App-scope holder for the process-wide ACP
 * client connection used by the ACP-backed `IHostFileSystem` to reverse-RPC
 * file text reads/writes to the editor (ACP `fs.readTextFile` /
 * `fs.writeTextFile`) and by the ACP-backed `ISessionProcessRunner` to
 * reverse-RPC command execution (`terminal/create` … `terminal/release`).
 *
 * One ACP client connection exists per `acp-server` process (a single stdio
 * connection, multiplexed by `sessionId`); it is established after
 * `bootstrap()`, so it is bound here lazily via {@link IAcpConnection.bind}
 * rather than seeded at composition time. The ACP-backed `IHostFileSystem`
 * (Session scope) and the ACP-backed process runner (Agent scope) read it on
 * first use through {@link IAcpConnection.get}.
 */

import {
  createDecorator,
  LifecycleScope,
  registerScopedService,
  ScopeActivation,
  type ServiceIdentifier,
} from '@moonshot-ai/agent-core-v2';

/**
 * Narrow ACP-client file surface the ACP-backed `IHostFileSystem` needs.
 *
 * Implemented by `../acp-client`'s `AcpClient` (the app-API outbound
 * adapter), so the host can `bind(client)` directly without a further
 * adapter.
 */
export interface IAcpFsClient {
  readTextFile(params: {
    readonly sessionId: string;
    readonly path: string;
  }): Promise<{ readonly content: string }>;
  writeTextFile(params: {
    readonly sessionId: string;
    readonly path: string;
    readonly content: string;
  }): Promise<unknown>;
}

/**
 * Narrow ACP-client terminal handle the ACP-backed process runner needs.
 * Structurally compatible with `@agentclientprotocol/sdk`'s `TerminalHandle`.
 */
export interface IAcpTerminalHandle {
  readonly id: string;
  currentOutput(): Promise<{ readonly output: string; readonly truncated: boolean }>;
  waitForExit(): Promise<{
    readonly exitCode?: number | null;
    readonly signal?: string | null;
  }>;
  kill(): Promise<unknown>;
  release(): Promise<unknown>;
}

/**
 * Narrow ACP-client terminal surface. Implemented by `../acp-client`'s
 * `AcpClient.createTerminal`.
 */
export interface IAcpTerminalClient {
  createTerminal(params: {
    readonly sessionId: string;
    readonly command: string;
    readonly args?: string[];
    readonly env?: Array<{ readonly name: string; readonly value: string }>;
    readonly cwd?: string | null;
    readonly outputByteLimit?: number | null;
  }): Promise<IAcpTerminalHandle>;
}

/**
 * Notification that a terminal was created for a session. The ACP adapter
 * (`AcpSession`) uses it to correlate the terminal with the in-flight Bash
 * tool call and attach a `{type: 'terminal'}` content entry to the tool card.
 */
export interface AcpTerminalCreatedEvent {
  readonly sessionId: string;
  /**
   * The full shell invocation string (the `-c` payload of the exec call,
   * `cd <cwd> && <command>`), used to match the tool call whose
   * `args.command` it ends with.
   */
  readonly shellCommand: string;
  readonly terminalId: string;
}

export type AcpTerminalCreatedListener = (event: AcpTerminalCreatedEvent) => void;

/**
 * How long a parked terminal release waits for the session to claim it
 * (see {@link IAcpConnection.deferTerminalRelease}) before releasing on its
 * own. The claim normally lands a few milliseconds after the command exits —
 * it only fires when the terminal was never correlated with a tool call (a
 * subagent's command, a cancelled turn), which must not leak the client-side
 * terminal until the session closes.
 */
const DEFERRED_RELEASE_FALLBACK_MS = 5_000;

/** A terminal whose `terminal/release` is parked until the session claims it. */
interface DeferredTerminalRelease {
  readonly sessionId: string;
  readonly release: () => Promise<unknown>;
  readonly timer: ReturnType<typeof setTimeout>;
}

export interface IAcpConnection {
  readonly _serviceBrand: undefined;
  /** Bind the process-wide ACP client connection. Later binds replace earlier ones. */
  bind(client: IAcpFsClient & IAcpTerminalClient): void;
  /** The bound ACP client connection. Throws if called before {@link bind}. */
  get(): IAcpFsClient & IAcpTerminalClient;
  /** Whether a client connection has been bound. */
  readonly bound: boolean;
  /** Bind the client's FS capabilities (from the `initialize` handshake). */
  bindFsCapabilities(fs: { readTextFile?: boolean; writeTextFile?: boolean } | undefined): void;
  /** Whether the client supports `fs.readTextFile`. */
  readonly fsReadTextFile: boolean;
  /** Whether the client supports `fs.writeTextFile`. */
  readonly fsWriteTextFile: boolean;
  /** Bind the client's terminal capability (from the `initialize` handshake). */
  bindTerminalCapability(terminal: boolean | undefined): void;
  /** Whether the client supports the `terminal/*` reverse-RPC surface. */
  readonly terminalEnabled: boolean;
  /** Notify listeners that a terminal was created (called by the ACP runner). */
  notifyTerminalCreated(event: AcpTerminalCreatedEvent): void;
  /** Subscribe to terminal-created notifications. Returns an unsubscribe. */
  onTerminalCreated(listener: AcpTerminalCreatedListener): () => void;
  /**
   * Park a terminal's `terminal/release` until the session has reported the
   * terminal's **final** state to the client.
   *
   * Ordering is load-bearing: the ACP runner disposes a process inside the
   * Bash tool's `finally`, which runs BEFORE the engine publishes
   * `tool.result`. Releasing there deletes the terminal at the client while
   * the session still owes a `tool_call_update` for that call — and clients
   * reject an update that references a terminal they no longer hold (Zed:
   * `Terminal with id ... not found`), which wedges the client's whole
   * session-update pipeline: no further UI updates land, the prompt never
   * settles, yet the agent keeps working. Parking the release lets the
   * session flush the final update first and then call
   * {@link releaseTerminal}.
   *
   * The release is fire-and-forget — a client that never answers must not
   * block the tool call. A fallback timer releases the terminal when no
   * session claims it (uncorrelated call, cancelled turn, teardown).
   */
  deferTerminalRelease(sessionId: string, terminalId: string, release: () => Promise<unknown>): void;
  /** Release a parked terminal now (idempotent; no-op for an unknown id). */
  releaseTerminal(terminalId: string): void;
  /** Release every terminal parked for a session (session teardown). */
  releaseSessionTerminals(sessionId: string): void;
}

export const IAcpConnection: ServiceIdentifier<IAcpConnection> =
  createDecorator<IAcpConnection>('acpConnection');

export class AcpConnection implements IAcpConnection {
  declare readonly _serviceBrand: undefined;

  private client: (IAcpFsClient & IAcpTerminalClient) | undefined;
  private _fsReadTextFile = false;
  private _fsWriteTextFile = false;
  private _terminalEnabled = false;
  private readonly terminalCreatedListeners = new Set<AcpTerminalCreatedListener>();
  private readonly deferredReleases = new Map<string, DeferredTerminalRelease>();

  bind(client: IAcpFsClient & IAcpTerminalClient): void {
    this.client = client;
  }

  get(): IAcpFsClient & IAcpTerminalClient {
    if (this.client === undefined) {
      throw new Error(
        'IAcpConnection.get() called before bind() — acp-server must bind the ACP client connection before any session performs file or terminal IO.',
      );
    }
    return this.client;
  }

  get bound(): boolean {
    return this.client !== undefined;
  }

  bindFsCapabilities(fs: { readTextFile?: boolean; writeTextFile?: boolean } | undefined): void {
    this._fsReadTextFile = fs?.readTextFile === true;
    this._fsWriteTextFile = fs?.writeTextFile === true;
  }

  get fsReadTextFile(): boolean {
    return this._fsReadTextFile;
  }

  get fsWriteTextFile(): boolean {
    return this._fsWriteTextFile;
  }

  bindTerminalCapability(terminal: boolean | undefined): void {
    this._terminalEnabled = terminal === true;
  }

  get terminalEnabled(): boolean {
    return this._terminalEnabled;
  }

  notifyTerminalCreated(event: AcpTerminalCreatedEvent): void {
    for (const listener of this.terminalCreatedListeners) {
      try {
        listener(event);
      } catch {
        // A broken listener must not take down process execution.
      }
    }
  }

  onTerminalCreated(listener: AcpTerminalCreatedListener): () => void {
    this.terminalCreatedListeners.add(listener);
    return () => {
      this.terminalCreatedListeners.delete(listener);
    };
  }

  deferTerminalRelease(
    sessionId: string,
    terminalId: string,
    release: () => Promise<unknown>,
  ): void {
    // A re-created id supersedes the parked entry (the client reuses ids
    // freely); drop the stale timer so it cannot release the new terminal.
    const previous = this.deferredReleases.get(terminalId);
    if (previous !== undefined) clearTimeout(previous.timer);
    const timer = setTimeout(() => {
      this.runTerminalRelease(terminalId);
    }, DEFERRED_RELEASE_FALLBACK_MS);
    timer.unref?.();
    this.deferredReleases.set(terminalId, { sessionId, release, timer });
  }

  releaseTerminal(terminalId: string): void {
    this.runTerminalRelease(terminalId);
  }

  releaseSessionTerminals(sessionId: string): void {
    for (const [terminalId, entry] of [...this.deferredReleases]) {
      if (entry.sessionId === sessionId) this.runTerminalRelease(terminalId);
    }
  }

  /**
   * Take a parked release and run it. Errors are swallowed: a client that
   * refuses a stale `terminal/release` must not surface as a turn failure.
   */
  private runTerminalRelease(terminalId: string): void {
    const entry = this.deferredReleases.get(terminalId);
    if (entry === undefined) return;
    this.deferredReleases.delete(terminalId);
    clearTimeout(entry.timer);
    try {
      void Promise.resolve(entry.release()).catch(() => {});
    } catch {
      // A synchronous throw from a broken client handle is equally harmless.
    }
  }
}

registerScopedService(
  LifecycleScope.App,
  IAcpConnection,
  AcpConnection,
  ScopeActivation.OnDemand,
  'acp',
);
