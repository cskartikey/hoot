// In-memory jobs with an event log, so an SSE client that connects late still gets every event.
import { randomBytes } from 'node:crypto';

export type JobEvent = { event: 'stage' | 'script' | 'done' | 'error'; data: Record<string, unknown> };

export interface Job {
  id: string;
  createdAt: number;
  status: 'running' | 'done' | 'error';
  events: JobEvent[];
  listeners: Set<(e: JobEvent) => void>;
  videoPath?: string;
  // Diagnostics (GET /jobs/:id, test runner)
  outcome?: 'first' | 'fixed' | 'fallback';
  attempts?: number;
  timings: Record<string, number>;
  errors: string[];
}

const jobs = new Map<string, Job>();

export function createJob(): Job {
  const id = randomBytes(6).toString('base64url').replace(/[-_]/g, 'x').toLowerCase();
  const job: Job = { id, createdAt: Date.now(), status: 'running', events: [], listeners: new Set(), timings: {}, errors: [] };
  jobs.set(id, job);
  // Forget jobs after 2 hours (files stay in out/).
  setTimeout(() => jobs.delete(id), 2 * 60 * 60 * 1000).unref();
  return job;
}

export const getJob = (id: string) => jobs.get(id);
export const jobCount = () => jobs.size;

export function emit(job: Job, event: JobEvent['event'], data: Record<string, unknown>) {
  const e = { event, data };
  job.events.push(e);
  if (event === 'done') job.status = 'done';
  if (event === 'error') job.status = 'error';
  for (const l of job.listeners) l(e);
}

export function summary(job: Job) {
  return {
    id: job.id,
    status: job.status,
    outcome: job.outcome,
    attempts: job.attempts,
    timings: job.timings,
    errors: job.errors,
    events: job.events,
  };
}
