import type { Page } from '@playwright/test';
import { expect, seed, test } from './fixtures/seed';

/** Load the dashboard and wait for app.js's first poll to finish rendering. */
async function openDashboard(page: Page): Promise<void> {
  await page.goto('/');
  await expect(page.getByTestId('refreshed')).toContainText('Updated');
}

function job(page: Page, id: string) {
  return page.locator(`[data-testid="job"][data-job-id="${id}"]`);
}

test('renders each job in its section with the right state badge', async ({ page }) => {
  const ripping = seed.job('Rip', { State: 'Ripping', Title: 'Alien (1979)', Drive: 'D:', DiscType: 'DVD', DiscLabel: 'ALIEN' });
  const complete = seed.job('Rip', { State: 'Complete', Title: 'Heat (1995)', DestDir: 'C:\\nas\\Heat (1995)' });
  const failed = seed.job('Rip', { State: 'Failed', Title: 'Ran (1985)', Error: 'Move to NAS failed: robocopy exit 16' });
  const queued = seed.job('Upscale', { State: 'Queued', Title: 'Brazil (1985)' });
  const review = seed.job('Upscale', { State: 'AwaitingReview', Title: 'Akira (1988)', SamplePath: 'C:\\q\\Akira sample.mkv' });

  await openDashboard(page);

  const active = page.getByTestId('active-rip');
  await expect(job(page, ripping)).toHaveCount(1);
  await expect(active.locator(`[data-job-id="${ripping}"] [data-testid="job-state"]`)).toHaveText('Ripping');
  await expect(active.locator(`[data-job-id="${ripping}"]`)).toContainText('ALIEN');

  const history = page.getByTestId('rip-history');
  await expect(history.locator(`[data-job-id="${complete}"] [data-testid="job-state"]`)).toHaveText('Complete');
  await expect(history.locator(`[data-job-id="${complete}"]`)).toContainText('C:\\nas\\Heat (1995)');
  await expect(history.locator(`[data-job-id="${failed}"] [data-testid="job-state"]`)).toHaveText('Failed');
  await expect(history.locator(`[data-job-id="${failed}"]`)).toContainText('robocopy exit 16');

  const upscale = page.getByTestId('upscale-queue');
  await expect(upscale.locator(`[data-job-id="${queued}"] [data-testid="job-state"]`)).toHaveText('Queued');
  await expect(upscale.locator(`[data-job-id="${review}"] [data-testid="job-state"]`)).toHaveText('AwaitingReview');
  await expect(upscale.locator(`[data-job-id="${review}"]`)).toContainText('Akira sample.mkv');

  // Finished rips never appear in the active section, and vice versa.
  await expect(active.locator(`[data-job-id="${complete}"]`)).toHaveCount(0);
  await expect(history.locator(`[data-job-id="${ripping}"]`)).toHaveCount(0);
});

test('renders a markup-bearing title as literal text (no XSS)', async ({ page }) => {
  const payload = '<img src=x onerror=alert(1)>';
  const scriptPayload = '<script>alert(2)</script>';
  const rip = seed.job('Rip', { State: 'Ripping', Title: payload });
  const upscale = seed.job('Upscale', { State: 'Queued', Title: scriptPayload });

  const dialogs: string[] = [];
  page.on('dialog', async (dialog) => {
    dialogs.push(dialog.message());
    await dialog.dismiss();
  });

  // Check the server-rendered HTML (before app.js runs) as well as the re-render.
  const response = await page.request.get('/');
  const html = await response.text();
  expect(html).toContain('&lt;img src=x onerror=alert(1)&gt;');
  expect(html).not.toContain(payload);

  await openDashboard(page);
  await expect(job(page, rip).getByTestId('job-title')).toHaveText(payload);
  await expect(job(page, upscale).getByTestId('job-title')).toHaveText(scriptPayload);
  await expect(job(page, rip).locator('img')).toHaveCount(0);
  await expect(page.locator('main img, main script')).toHaveCount(0);

  // Give a would-be onerror handler time to fire across one more poll.
  await page.waitForTimeout(5_500);
  expect(dialogs).toEqual([]);
});

test('picks up job changes by polling, without a page reload', async ({ page }) => {
  const id = seed.job('Rip', { State: 'Ripping', Title: 'Polling Test' });
  await openDashboard(page);
  await expect(job(page, id).getByTestId('job-state')).toHaveText('Ripping');

  // A marker on window survives only if the page is never reloaded.
  await page.evaluate(() => ((window as unknown as { __noReload: boolean }).__noReload = true));
  let navigations = 0;
  page.on('framenavigated', (frame) => {
    if (frame === page.mainFrame()) navigations += 1;
  });

  seed.update(id, { State: 'Moving' });
  await expect(job(page, id).getByTestId('job-state')).toHaveText('Moving', { timeout: 10_000 });

  seed.update(id, { State: 'Complete', DestDir: 'C:\\nas\\Polling Test' });
  await expect(page.getByTestId('rip-history').locator(`[data-job-id="${id}"] [data-testid="job-state"]`)).toHaveText(
    'Complete',
    { timeout: 10_000 },
  );
  await expect(page.getByTestId('active-rip').locator(`[data-job-id="${id}"]`)).toHaveCount(0);
  await expect(page.getByTestId('empty-rips')).toHaveText('No rip in progress');

  expect(await page.evaluate(() => (window as unknown as { __noReload?: boolean }).__noReload)).toBe(true);
  expect(navigations).toBe(0);
});

test('shows the tail of today\'s log as plain text', async ({ page }) => {
  seed.log(['[2026-09-28 10:00:00] [INFO] first line', '[2026-09-28 10:00:01] [WARN] <b>not bold</b>']);
  await openDashboard(page);

  const log = page.getByTestId('log-tail');
  await expect(log).toHaveText('[2026-09-28 10:00:00] [INFO] first line\n[2026-09-28 10:00:01] [WARN] <b>not bold</b>');
  await expect(log.locator('b')).toHaveCount(0);

  seed.log(['[2026-09-28 10:05:00] [INFO] a newer line']);
  await expect(log).toHaveText('[2026-09-28 10:05:00] [INFO] a newer line', { timeout: 10_000 });
});

test('shows the empty state when there are no jobs', async ({ page }) => {
  await openDashboard(page);
  await expect(page.getByTestId('empty-rips')).toHaveText('No rips yet');
  await expect(page.getByTestId('rip-history')).toContainText('No finished rips');
  await expect(page.getByTestId('upscale-queue')).toContainText('No upscale jobs');
  await expect(page.locator('[data-testid="job"]')).toHaveCount(0);
});
