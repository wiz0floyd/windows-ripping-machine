import * as fs from 'node:fs';
import * as path from 'node:path';
import type { Page } from '@playwright/test';
import { env, expect, seed, test } from './fixtures/seed';

const ACTION = { 'X-WRM-Action': '1' };

async function openDashboard(page: Page): Promise<void> {
  await page.goto('/');
  await expect(page.getByTestId('refreshed')).toContainText('Updated');
}

function card(page: Page, id: string) {
  return page.locator(`[data-testid="job"][data-job-id="${id}"]`);
}

function readMeta(stagingDir: string): { Title: string; Year: string } {
  return JSON.parse(fs.readFileSync(path.join(stagingDir, 'metadata.json'), 'utf8'));
}

test('prefills from metadata.json, previews the folder name, saves, and the pipeline names the NAS folder from it', async ({ page }) => {
  const rip = seed.rip({ DiscLabel: 'EDIT_DISC_ONE', Title: 'Old Guess (1999)', MetaTitle: 'Old Guess', MetaYear: '1999' });
  await openDashboard(page);

  const form = card(page, rip.JobId).getByTestId('meta-form');
  await expect(form).toBeVisible();
  await expect(form.getByTestId('meta-title')).toHaveValue('Old Guess');
  await expect(form.getByTestId('meta-year')).toHaveValue('1999');
  await expect(form.getByTestId('meta-folder')).toHaveText('Old Guess (1999)');

  // The preview is computed server-side with the pipeline's sanitising rule.
  await form.getByTestId('meta-title').fill('Brand: New / Title?');
  await form.getByTestId('meta-year').fill('2001');
  await expect(form.getByTestId('meta-folder')).toHaveText('Brand New Title (2001)');

  await form.getByTestId('meta-save').click();
  await expect(form.getByTestId('meta-message')).toContainText('Saved');
  expect(readMeta(rip.StagingDir)).toEqual({ Title: 'Brand: New / Title?', Year: '2001' });
  await expect(card(page, rip.JobId).getByTestId('job-title')).toHaveText('Brand New Title (2001)');

  // Finish the rip through the real Invoke-VideoDispatch tail.
  seed.finishRip(rip.JobId);
  const nasFolder = path.join(env.nasVideoPath, 'Brand New Title (2001)');
  expect(fs.existsSync(path.join(nasFolder, 'title_t00.mkv'))).toBe(true);
  expect(fs.existsSync(path.join(env.nasVideoPath, 'Old Guess (1999)'))).toBe(false);

  await expect(card(page, rip.JobId).getByTestId('job-state')).toHaveText('Complete', { timeout: 10_000 });
});

test('an unedited rip keeps its original name through the pipeline', async ({ page }) => {
  const rip = seed.rip({ DiscLabel: 'EDIT_DISC_TWO', Title: 'Untouched Movie (1988)', MetaTitle: 'Untouched Movie', MetaYear: '1988' });
  await openDashboard(page);
  await expect(card(page, rip.JobId).getByTestId('meta-form')).toBeVisible();

  seed.finishRip(rip.JobId);
  expect(fs.existsSync(path.join(env.nasVideoPath, 'Untouched Movie (1988)', 'title_t00.mkv'))).toBe(true);
});

test('validation: blank title and a 2-digit year show inline errors and nothing is written', async ({ page }) => {
  const rip = seed.rip({ DiscLabel: 'EDIT_DISC_THREE', MetaTitle: 'Keep Me', MetaYear: '1990' });
  await openDashboard(page);
  const form = card(page, rip.JobId).getByTestId('meta-form');
  await expect(form.getByTestId('meta-title')).toHaveValue('Keep Me');

  await form.getByTestId('meta-title').fill('   ');
  await expect(form.getByTestId('meta-error-title')).toContainText('required');
  await expect(form.getByTestId('meta-save')).toBeDisabled();

  await form.getByTestId('meta-title').fill('Fine Title');
  await form.getByTestId('meta-year').fill('99');
  await expect(form.getByTestId('meta-error-year')).toContainText('4 digits');
  await expect(form.getByTestId('meta-save')).toBeDisabled();

  await form.getByTestId('meta-year').fill('1999');
  await expect(form.getByTestId('meta-error-year')).toHaveText('');
  await expect(form.getByTestId('meta-save')).toBeEnabled();

  // A forced POST is refused by the server too, and the file is unchanged.
  for (const body of [{ Title: '', Year: '1999' }, { Title: 'X', Year: '99' }, { Title: ':::', Year: '' }]) {
    const response = await page.request.post(`/api/jobs/${rip.JobId}/metadata`, { headers: ACTION, data: body });
    expect(response.status(), JSON.stringify(body)).toBe(400);
  }
  expect(readMeta(rip.StagingDir)).toEqual({ Title: 'Keep Me', Year: '1990' });
});

test('half-typed text survives the 5 s poll', async ({ page }) => {
  const rip = seed.rip({ DiscLabel: 'EDIT_DISC_FOUR', MetaTitle: 'Before', MetaYear: '' });
  await openDashboard(page);
  const title = card(page, rip.JobId).getByTestId('meta-title');
  await expect(title).toHaveValue('Before');

  await title.fill('Half typed');
  await title.focus();
  await page.waitForTimeout(5800); // one full poll interval
  await expect(card(page, rip.JobId).getByTestId('meta-title')).toHaveValue('Half typed');
  await expect(card(page, rip.JobId).getByTestId('meta-title')).toBeFocused();
});

test('a rip that is already Moving shows a read-only form, and a forced POST gets 409', async ({ page }) => {
  const rip = seed.rip({ DiscLabel: 'EDIT_DISC_FIVE', State: 'Moving', MetaTitle: 'Locked In', MetaYear: '2005' });
  await openDashboard(page);

  const form = card(page, rip.JobId).getByTestId('meta-form');
  await expect(form.getByTestId('meta-title')).toHaveValue('Locked In');
  await expect(form.getByTestId('meta-title')).not.toBeEditable();
  await expect(form.getByTestId('meta-year')).not.toBeEditable();
  await expect(form.getByTestId('meta-save')).toBeDisabled();
  await expect(form.getByTestId('meta-message')).toContainText('Moving');

  const response = await page.request.post(`/api/jobs/${rip.JobId}/metadata`, { headers: ACTION, data: { Title: 'Too Late', Year: '' } });
  expect(response.status()).toBe(409);
  expect(readMeta(rip.StagingDir)).toEqual({ Title: 'Locked In', Year: '2005' });
});

test('the form turns read-only when the rip moves on while the page is open', async ({ page }) => {
  const rip = seed.rip({ DiscLabel: 'EDIT_DISC_SIX', MetaTitle: 'Racing', MetaYear: '' });
  await openDashboard(page);
  const form = card(page, rip.JobId).getByTestId('meta-form');
  await expect(form.getByTestId('meta-title')).toBeEditable();

  seed.update(rip.JobId, { State: 'Moving' });
  await expect(form.getByTestId('meta-title')).not.toBeEditable({ timeout: 10_000 });
  await expect(form.getByTestId('meta-save')).toBeDisabled();
});

test('audio CD rips get no metadata form', async ({ page }) => {
  const rip = seed.rip({ DiscLabel: 'AUDIO_DISC', DiscType: 'AudioCD' });
  await openDashboard(page);
  await expect(card(page, rip.JobId)).toHaveCount(1);
  await expect(card(page, rip.JobId).getByTestId('meta-form')).toHaveCount(0);

  const response = await page.request.post(`/api/jobs/${rip.JobId}/metadata`, { headers: ACTION, data: { Title: 'T', Year: '' } });
  expect(response.status()).toBe(409);
});

test('a POST without the X-WRM-Action header is 403 and an unknown job is 404', async ({ page }) => {
  const rip = seed.rip({ DiscLabel: 'EDIT_DISC_SEVEN', MetaTitle: 'Csrf Safe', MetaYear: '' });
  const forged = await page.request.post(`/api/jobs/${rip.JobId}/metadata`, { data: { Title: 'Hacked', Year: '' } });
  expect(forged.status()).toBe(403);
  expect(readMeta(rip.StagingDir).Title).toBe('Csrf Safe');

  const missing = await page.request.post('/api/jobs/20000101-000000-abcdef/metadata', { headers: ACTION, data: { Title: 'T', Year: '' } });
  expect(missing.status()).toBe(404);
});

test('markup in a prefilled title is shown as text, never executed', async ({ page }) => {
  const evil = '<img src=x onerror="window.__pwned=1">';
  const rip = seed.rip({ DiscLabel: 'EDIT_DISC_EIGHT', Title: evil, MetaTitle: evil, MetaYear: '' });
  await openDashboard(page);
  const form = card(page, rip.JobId).getByTestId('meta-form');
  await expect(form.getByTestId('meta-title')).toHaveValue(evil);
  await expect(card(page, rip.JobId).getByTestId('job-title')).toHaveText(evil);
  expect(await page.evaluate(() => (window as unknown as { __pwned?: number }).__pwned)).toBeUndefined();
  await expect(page.locator('img[src="x"]')).toHaveCount(0);
});
