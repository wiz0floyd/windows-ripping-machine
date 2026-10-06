import { execFileSync } from 'node:child_process';
import { expect, test as base } from '@playwright/test';
import { ensureTestRoot } from './env';

export const env = ensureTestRoot();

type Props = Record<string, unknown>;

function runSeed(args: string[]): string {
  const out = execFileSync(
    'pwsh',
    ['-NoProfile', '-NonInteractive', '-File', env.seedScript, '-ConfigPath', env.configPath, ...args],
    { encoding: 'utf8', timeout: 60_000 },
  );
  return out.trim();
}

function b64(value: unknown): string {
  return Buffer.from(JSON.stringify(value), 'utf8').toString('base64');
}

/** Wraps fixtures/seed.ps1, which writes state through the real src/JobState.ps1. */
export const seed = {
  reset(): void {
    runSeed(['-Action', 'Reset']);
  },
  /** Creates a job and returns its id. */
  job(kind: 'Rip' | 'Upscale', props: Props = {}): string {
    const lines = runSeed(['-Action', 'New', '-Kind', kind, '-PropertiesB64', b64(props)]).split(/\r?\n/);
    const id = lines[lines.length - 1].trim();
    expect(id).toMatch(/^\d{8}-\d{6}-[0-9a-f]{6}$/);
    return id;
  },
  /** An Upscale job plus its queue file and stub source mkv on disk (see seed.ps1 NewUpscale). */
  upscale(
    ext: '.json' | '.awaiting-review' | '.failed',
    props: Props = {},
  ): { JobId: string; QueueFile: string; DestDir: string; Source: string } {
    const lines = runSeed(['-Action', 'NewUpscale', '-QueueExtension', ext, '-PropertiesB64', b64(props)]).split(/\r?\n/);
    return JSON.parse(lines[lines.length - 1]);
  },
  /** Runs one Upscale-Worker.ps1 -Simulate pass over the queue directory. */
  runWorkerOnce(): void {
    execFileSync(
      'pwsh',
      ['-NoProfile', '-NonInteractive', '-File', env.workerScript, '-Simulate', '-Once', '-ConfigPath', env.configPath],
      { encoding: 'utf8', timeout: 120_000 },
    );
  },
  update(jobId: string, props: Props): void {
    runSeed(['-Action', 'Update', '-JobId', jobId, '-PropertiesB64', b64(props)]);
  },
  log(lines: string[]): void {
    runSeed(['-Action', 'Log', '-PropertiesB64', b64(lines)]);
  },
};

/**
 * Base test for every spec: resets seeded state before each test and fails the
 * test if the page logged any console error or threw an uncaught exception.
 */
export const test = base.extend<{ consoleErrors: string[] }>({
  consoleErrors: [
    async ({ page }, use) => {
      seed.reset();
      const errors: string[] = [];
      page.on('console', (msg) => {
        if (msg.type() === 'error') errors.push(msg.text());
      });
      page.on('pageerror', (err) => errors.push(`pageerror: ${err.message}`));
      await use(errors);
      expect(errors, 'browser console errors').toEqual([]);
    },
    { auto: true },
  ],
});

export { expect };
