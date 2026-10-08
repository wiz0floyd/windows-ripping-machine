import { defineConfig, devices } from '@playwright/test';
import { ensureTestRoot, PORT } from './fixtures/env';

// One temp root per run (created at config load in the runner process; workers
// inherit it through process.env). WebUi.ps1 is launched against a config whose
// StateDir/LogDir/StagingDir/UpscaleQueueDir/NAS paths all live under it.
const env = ensureTestRoot();

export default defineConfig({
  testDir: '.',
  testMatch: '*.spec.ts',
  // Specs share one server and one StateDir, and each test resets it: run serially.
  fullyParallel: false,
  workers: 1,
  retries: process.env.CI ? 1 : 0,
  forbidOnly: !!process.env.CI,
  reporter: process.env.CI ? [['list'], ['html', { open: 'never' }]] : [['list']],
  globalTeardown: './fixtures/global-teardown.ts',
  use: {
    // 'localhost', never 127.0.0.1: HttpListener's prefix is http://localhost:<port>/
    // and HTTP.sys rejects any other Host header with 400 Invalid Hostname.
    baseURL: `http://localhost:${PORT}`,
    trace: 'retain-on-failure',
  },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
  webServer: {
    command: `pwsh -NoProfile -File "${env.webUiScript}" -Simulate -ConfigPath "${env.configPath}"`,
    url: `http://localhost:${PORT}/api/jobs`,
    reuseExistingServer: false,
    timeout: 60_000,
    stdout: 'ignore',
    stderr: 'pipe',
  },
});
