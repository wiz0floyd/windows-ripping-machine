import * as fs from 'node:fs';

export default async function globalTeardown(): Promise<void> {
  const root = process.env.WRM_TEST_ROOT;
  if (!root) return;
  try {
    fs.rmSync(root, { recursive: true, force: true, maxRetries: 3 });
  } catch {
    // The web server may still hold today's log open; the OS temp cleaner gets the rest.
  }
}
