import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';

export const PORT = 18765;

export const REPO_ROOT = path.resolve(__dirname, '..', '..', '..');

export interface TestEnv {
  /** Per-run temp root (WRM_TEST_ROOT). */
  root: string;
  /** Generated config.psd1 (WRM_TEST_CONFIG). */
  configPath: string;
  webUiScript: string;
  seedScript: string;
}

function psQuote(value: string): string {
  return `'${value.replace(/'/g, "''")}'`;
}

/**
 * Create the per-run temp root + config.psd1 once (in the runner process) and
 * publish it via env vars so worker processes reuse the same root.
 *
 * Layout under the root: state\ logs\ staging\ queue\ nas-video\ nas-music\ config.psd1
 */
export function ensureTestRoot(): TestEnv {
  let root = process.env.WRM_TEST_ROOT;
  let configPath = process.env.WRM_TEST_CONFIG;

  if (!root || !configPath) {
    root = fs.mkdtempSync(path.join(os.tmpdir(), 'wrm-browser-'));
    const dirs: Record<string, string> = {
      StateDir: path.join(root, 'state'),
      LogDir: path.join(root, 'logs'),
      StagingDir: path.join(root, 'staging'),
      UpscaleQueueDir: path.join(root, 'queue'),
      NasVideoPath: path.join(root, 'nas-video'),
      NasMusicPath: path.join(root, 'nas-music'),
    };
    for (const dir of Object.values(dirs)) fs.mkdirSync(dir, { recursive: true });

    const lines = Object.entries(dirs).map(([key, value]) => `    ${key} = ${psQuote(value)}`);
    lines.push(
      `    MakeMkvConPath = 'C:\\does-not-exist\\makemkvcon64.exe'`,
      `    FreacCmdPath = 'C:\\does-not-exist\\freaccmd.exe'`,
      `    FfmpegPath = 'ffmpeg'`,
      `    Video2xPath = 'C:\\does-not-exist\\video2x.exe'`,
      `    TmdbApiKey = ''`,
      `    HaWebhookUrl = ''`,
      `    UpscaleDvds = $false`,
      `    AutoUpscale = $false`,
      `    UpscaleActiveHours = @('00:00','23:59')`,
      `    WebUiEnabled = $true`,
      `    WebUiPort = ${PORT}`,
      `    Simulate = $true`,
    );
    configPath = path.join(root, 'config.psd1');
    fs.writeFileSync(configPath, `@{\n${lines.join('\n')}\n}\n`, 'utf8');

    process.env.WRM_TEST_ROOT = root;
    process.env.WRM_TEST_CONFIG = configPath;
  }

  return {
    root,
    configPath,
    webUiScript: path.join(REPO_ROOT, 'src', 'WebUi.ps1'),
    seedScript: path.join(REPO_ROOT, 'tests', 'browser', 'fixtures', 'seed.ps1'),
  };
}
