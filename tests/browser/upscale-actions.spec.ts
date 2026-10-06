import * as fs from 'node:fs';
import type { Page } from '@playwright/test';
import { expect, seed, test } from './fixtures/seed';

async function openDashboard(page: Page): Promise<void> {
  await page.goto('/');
  await expect(page.getByTestId('refreshed')).toContainText('Updated');
}

function row(page: Page, id: string) {
  return page.locator(`[data-testid="job"][data-job-id="${id}"]`);
}

const ACTION = { 'X-WRM-Action': '1' };

test('approve: renames the queue file, then the worker completes the job', async ({ page }) => {
  const job = seed.upscale('.awaiting-review', { State: 'AwaitingReview', Title: 'Approve Me (2001)', SamplePath: 'C:\q\sample.mkv' });
  await openDashboard(page);

  await expect(row(page, job.JobId).getByTestId('copy-sample')).toBeVisible();
  await expect(row(page, job.JobId).getByTestId('action-retry')).toHaveCount(0);
  await row(page, job.JobId).getByTestId('action-approve').click();

  await expect(row(page, job.JobId).getByTestId('job-state')).toHaveText('Queued');
  expect(fs.existsSync(job.QueueFile)).toBe(false);
  const approved = job.QueueFile.replace(/\.awaiting-review$/, '.json');
  expect(fs.existsSync(approved)).toBe(true);

  seed.runWorkerOnce();
  await expect(row(page, job.JobId).getByTestId('job-state')).toHaveText('Complete', { timeout: 10_000 });
  expect(fs.existsSync(approved)).toBe(false);
});

test('retry: a failed job goes back to Queued as .json', async ({ page }) => {
  const job = seed.upscale('.failed', { State: 'Failed', Title: 'Retry Me (2002)', Error: 'video2x exited 1' });
  await openDashboard(page);

  await row(page, job.JobId).getByTestId('action-retry').click();
  await expect(row(page, job.JobId).getByTestId('job-state')).toHaveText('Queued');
  expect(fs.existsSync(job.QueueFile)).toBe(false);
  expect(fs.existsSync(job.QueueFile.replace(/\.failed$/, '.json'))).toBe(true);
});

test('cancel: confirm dialog, then the queue file is deleted', async ({ page }) => {
  const job = seed.upscale('.json', { State: 'Queued', Title: 'Cancel Me (2003)' });
  await openDashboard(page);

  page.once('dialog', (dialog) => dialog.accept());
  await row(page, job.JobId).getByTestId('action-cancel').click();
  await expect(row(page, job.JobId).getByTestId('job-state')).toHaveText('Cancelled');
  expect(fs.existsSync(job.QueueFile)).toBe(false);
});

test('cancel: dismissing the confirm dialog changes nothing', async ({ page }) => {
  const job = seed.upscale('.json', { State: 'Queued', Title: 'Keep Me (2004)' });
  await openDashboard(page);

  page.once('dialog', (dialog) => dialog.dismiss());
  await row(page, job.JobId).getByTestId('action-cancel').click();
  await page.waitForTimeout(500);
  await expect(row(page, job.JobId).getByTestId('job-state')).toHaveText('Queued');
  expect(fs.existsSync(job.QueueFile)).toBe(true);
});

test('buttons are absent for jobs the worker owns, and a forced POST gets 409', async ({ page }) => {
  const job = seed.upscale('.json', { State: 'Upscaling', Title: 'Busy (2005)' });
  await openDashboard(page);

  await expect(row(page, job.JobId)).toHaveCount(1);
  await expect(row(page, job.JobId).locator('button[data-action]')).toHaveCount(0);

  for (const action of ['approve', 'retry', 'cancel']) {
    const response = await page.request.post(`/api/jobs/${job.JobId}/${action}`, { headers: ACTION });
    expect(response.status(), action).toBe(409);
  }
  expect(fs.existsSync(job.QueueFile)).toBe(true);
});

test('a POST without the X-WRM-Action header is rejected with 403', async ({ page }) => {
  const job = seed.upscale('.json', { State: 'Queued', Title: 'Csrf (2006)' });
  const response = await page.request.post(`/api/jobs/${job.JobId}/cancel`);
  expect(response.status()).toBe(403);
  expect(fs.existsSync(job.QueueFile)).toBe(true);
});

test('an unknown job id is a 404', async ({ page }) => {
  const response = await page.request.post('/api/jobs/20000101-000000-abcdef/approve', { headers: ACTION });
  expect(response.status()).toBe(404);
});
