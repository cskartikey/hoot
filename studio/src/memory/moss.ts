// hoot's memory search on Moss (https://moss.dev), written at Cal Hacks 13.0.
//
// The app keeps its memories in memory.json; this mirrors each one into a Moss
// index so recall can rank them by meaning instead of shared words.
//
// Design (Moss's own guidance for data created during a live interaction):
// - On start, open a SESSION named after the index and pull the cloud index
//   into it (`session.loadIndex`): no re-embedding, the prebuilt vectors load.
// - New memories go into the session with `addDocs` (embedded in-process with
//   moss-mediumlm, no network round trip) and are queryable at once.
// - Queries run against the session in process memory (~1-10 ms).
// - The session is pushed to the cloud 30 s after the last change, and on
//   shutdown, so memories survive a restart. A push REPLACES the cloud index,
//   so we only push when the cloud copy was loaded first (otherwise a network
//   blip at startup would wipe older memories).
// Without MOSS_PROJECT_ID / MOSS_PROJECT_KEY everything reports
// { enabled: false } and the app keeps its on-device recall.
import { MossClient, isMossError, type SessionIndex } from '@moss-js/moss';

export type MemoryDocument = { id: string; text: string; metadata?: Record<string, string> };
export type MemoryHit = { id: string; score: number; concept?: string };

/** Picked by test/moss-memory.ts; see the README "Moss" section. */
export const DEFAULT_ALPHA = 0.8;
const MODEL_ID = 'moss-mediumlm';
const RETRY_OPEN_AFTER_MS = 30_000;

export class MossMemoryIndex {
  readonly enabled: boolean;
  private client: MossClient | null = null;
  private session: SessionIndex | null = null;
  private opening: Promise<SessionIndex | null> | null = null;
  private lastOpenFailureAt = 0;
  private lastError = '';
  /** True once the cloud copy was pulled in (or known not to exist): only then is a push safe. */
  private cloudCopyLoaded = false;
  private pushTimer: ReturnType<typeof setTimeout> | undefined;
  private hasUnpushedChanges = false;
  private lastPushedAt: string | null = null;
  /** Mutations (add, reset, push) run one at a time, in order. */
  private writeChain: Promise<unknown> = Promise.resolve();

  constructor(
    private readonly projectId: string,
    private readonly projectKey: string,
    readonly indexName: string,
    private readonly pushDelayMs = 30_000,
  ) {
    this.enabled = Boolean(projectId && projectKey);
  }

  /** Opens the session in the background so the first query is warm. */
  start() {
    if (this.enabled) void this.openSession();
  }

  private openSession(): Promise<SessionIndex | null> {
    if (this.session) return Promise.resolve(this.session);
    if (!this.enabled) return Promise.resolve(null);
    if (this.opening) return this.opening;
    if (Date.now() - this.lastOpenFailureAt < RETRY_OPEN_AFTER_MS) return Promise.resolve(null);
    const started = Date.now();
    this.opening = (async () => {
      try {
        this.client ??= new MossClient(this.projectId, this.projectKey);
        const session = await this.client.session(this.indexName, MODEL_ID);
        try {
          const loadedCount = await session.loadIndex(this.indexName);
          this.cloudCopyLoaded = true;
          console.log(`[moss] session "${this.indexName}" ready: ${loadedCount} memories from the cloud, model ${session.modelId}, ${Date.now() - started} ms`);
        } catch (e) {
          // Keep the session for local use, but never push over a cloud copy we couldn't read.
          this.cloudCopyLoaded = false;
          this.lastError = describe(e);
          console.warn(`[moss] couldn't load the cloud index into the session (${this.lastError}); local only, no push`);
        }
        this.session = session;
        return session;
      } catch (e) {
        this.lastOpenFailureAt = Date.now();
        this.lastError = describe(e);
        console.warn(`[moss] couldn't open a session: ${this.lastError}`);
        return null;
      } finally {
        this.opening = null;
      }
    })();
    return this.opening;
  }

  private enqueueWrite<T>(work: () => Promise<T>): Promise<T> {
    const next = this.writeChain.then(work, work);
    this.writeChain = next.catch(() => undefined);
    return next;
  }

  async health() {
    if (!this.enabled) return { enabled: false as const };
    const session = await this.openSession();
    return {
      enabled: true as const,
      ready: Boolean(session),
      indexName: this.indexName,
      model: session?.modelId ?? MODEL_ID,
      documentCount: session ? session.docCount : undefined,
      cloudCopyLoaded: this.cloudCopyLoaded,
      unpushedChanges: this.hasUnpushedChanges,
      lastPushedAt: this.lastPushedAt,
      ...(session ? {} : { error: this.lastError || 'session not open yet' }),
    };
  }

  /** Adds or replaces memories in the session (instant, local) and schedules a push. */
  upsert(documents: MemoryDocument[]) {
    return this.enqueueWrite(async () => {
      const session = await this.openSession();
      if (!session) return { enabled: this.enabled, ok: false, error: this.lastError || 'not ready' };
      const { added, updated } = await session.addDocs(documents, { upsert: true });
      this.hasUnpushedChanges = true;
      this.schedulePush();
      return { enabled: true, ok: true, added, updated, documentCount: session.docCount };
    });
  }

  /**
   * Each text is queried on its own (question, video title, transcript lines)
   * so a long transcript doesn't drown the question; a memory keeps its best score.
   * Moss's `score` is the semantic similarity rescaled to 0..1; `alpha` sets the
   * hybrid (semantic + BM25) ranking that decides which candidates come back.
   */
  async query(texts: string[], topK = 5, alpha = DEFAULT_ALPHA) {
    if (!this.enabled) return { enabled: false as const, results: [] as MemoryHit[] };
    const session = this.session;
    if (!session) {
      void this.openSession();
      return { enabled: true as const, ready: false, results: [] as MemoryHit[] };
    }
    const started = performance.now();
    const best = new Map<string, MemoryHit>();
    for (const text of texts) {
      const result = await session.query(text, { topK, alpha });
      for (const doc of result.docs) {
        const previous = best.get(doc.id);
        if (!previous || doc.score > previous.score) {
          best.set(doc.id, { id: doc.id, score: doc.score, concept: doc.metadata?.concept });
        }
      }
    }
    const results = [...best.values()].sort((a, b) => b.score - a.score).slice(0, topK);
    return { enabled: true as const, ready: true, results, tookMs: Number((performance.now() - started).toFixed(2)) };
  }

  /** "Forget everything": empties the session and deletes the cloud index. */
  reset() {
    return this.enqueueWrite(async () => {
      if (!this.enabled) return { enabled: false };
      clearTimeout(this.pushTimer);
      this.hasUnpushedChanges = false;
      const session = await this.openSession();
      if (session && session.docCount > 0) {
        const allDocs = await session.getDocs();
        if (allDocs.length) await session.deleteDocs(allDocs.map((d) => d.id));
      }
      let deletedCloudIndex = false;
      try {
        this.client ??= new MossClient(this.projectId, this.projectKey);
        deletedCloudIndex = await this.client.deleteIndex(this.indexName);
      } catch (e) {
        if (!(isMossError(e) && e.code === 'NOT_FOUND')) {
          console.warn(`[moss] reset: couldn't delete the cloud index: ${describe(e)}`);
          return { enabled: true, ok: false, error: describe(e) };
        }
      }
      // The cloud copy is now known to be empty, so later pushes are safe.
      this.cloudCopyLoaded = true;
      console.log(`[moss] reset "${this.indexName}" (cloud index deleted: ${deletedCloudIndex})`);
      return { enabled: true, ok: true, documentCount: session?.docCount ?? 0 };
    });
  }

  private schedulePush() {
    clearTimeout(this.pushTimer);
    this.pushTimer = setTimeout(() => void this.pushNow(), this.pushDelayMs);
    this.pushTimer.unref?.();
  }

  /** Persists the session to the cloud index (replacing it). */
  pushNow() {
    return this.enqueueWrite(async () => {
      clearTimeout(this.pushTimer);
      const session = this.session;
      if (!session || !this.hasUnpushedChanges) return { pushed: false };
      if (!this.cloudCopyLoaded) {
        console.warn('[moss] not pushing: the cloud copy was never loaded, a push would replace it');
        return { pushed: false };
      }
      if (session.docCount === 0) return { pushed: false };
      const started = Date.now();
      try {
        const result = await session.pushIndex();
        this.hasUnpushedChanges = false;
        this.lastPushedAt = new Date().toISOString();
        console.log(`[moss] pushed ${result.docCount} memories to "${this.indexName}" in ${Date.now() - started} ms`);
        return { pushed: true, docCount: result.docCount };
      } catch (e) {
        this.lastError = describe(e);
        console.warn(`[moss] push failed: ${this.lastError}`);
        this.schedulePush();
        return { pushed: false, error: this.lastError };
      }
    });
  }

  /** Pushes pending changes, then frees the client. Used on shutdown and by tests. */
  async close() {
    await this.pushNow().catch(() => undefined);
    await this.client?.close().catch(() => undefined);
    this.client = null;
    this.session = null;
  }
}

function describe(e: unknown): string {
  if (isMossError(e)) return `${e.code}: ${e.message}`;
  return e instanceof Error ? e.message : String(e);
}
