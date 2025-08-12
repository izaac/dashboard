/* eslint-disable no-console */
/* eslint-disable padding-line-between-statements */
import path from 'path';

type AfterSpecResults = any;

const QASE_ID_REGEX = /Qase[\s_]*ID[:\s_]*(\d+)/i;

// Wait until a file exists, is non-empty, and its size stabilizes
async function waitForReady(filePath: string, timeoutMs = 20000, intervalMs = 500): Promise<boolean> {
  const fs = require('fs');
  const start = Date.now();
  let lastSize = -1;

  while (Date.now() - start < timeoutMs) {
    try {
      if (fs.existsSync(filePath)) {
        const { size } = fs.statSync(filePath);
        if (size > 0) {
          if (lastSize === size) return true; // size stabilized

          lastSize = size;
        }
      }
    } catch {}

    // eslint-disable-next-line no-promise-executor-return
    await new Promise((resolve) => setTimeout(resolve, intervalMs));
  }

  return require('fs').existsSync(filePath);
}

// Build a mapping from caseId -> list of screenshot file paths that mention that caseId
function mapScreenshotsByCaseId(screenshots: string[]): Map<number, string[]> {
  const map = new Map<number, string[]>();

  for (const s of screenshots) {
    const text = s || '';
    const m = text.match(QASE_ID_REGEX);
    if (m && m[1]) {
      const id = Number(m[1]);

      if (!Number.isNaN(id)) {
        const list = map.get(id) || [];

        list.push(s);
        map.set(id, list);
      }
    }
  }

  return map;
}

async function uploadFilesForCase(params: {
  token: string;
  projectCode: string;
  runId: number;
  caseId: number;
  files: Array<{ name: string; value: any }>;
  status: 'passed' | 'failed';
}) {
  const {
    token,
    projectCode,
    runId,
    caseId,
    files,
    status
  } = params;

  const { Configuration, AttachmentsApi, ResultsApi } = require('qase-api-client');
  const FormData = require('form-data');

  const qaseConfig = new Configuration({ apiKey: token, formDataCtor: FormData });
  const attachmentsApi = new AttachmentsApi(qaseConfig);
  const resultsApi = new ResultsApi(qaseConfig);

  const hashes: string[] = [];
  for (const f of files) {
    try {
      const singleResp: any = await attachmentsApi.uploadAttachment(projectCode, [f]);
      const fileHashes: string[] = (singleResp?.data?.result || [])
        .map((x: any) => x?.hash)
        .filter((h: string) => !!h);

      if (fileHashes.length) {
        hashes.push(...fileHashes);
        console.log(`[Qase] uploaded '${ f?.name }'`);
      } else {
        console.log(`[Qase] no hash returned for '${ f?.name }'`);
      }
    } catch (fileErr) {
      console.log(`[Qase] failed to upload '${ f?.name }':`, fileErr?.message || fileErr);
    }
  }

  const resultBody: any = {
    status,
    case_id:     caseId,
    attachments: hashes,
    comment:     'Artifacts uploaded by after:spec helper'
  };
  await resultsApi.createResult(projectCode, runId, resultBody);
  console.log(`[Qase] attached ${ hashes.length } file(s) for case ${ caseId }`);
}

export function registerQaseArtifacts(on: any, config: any) {
  on('after:spec', async(_spec: any, results: AfterSpecResults) => {
    try {
      const fs = require('fs');

      const r: any = results as any;
      const videos: string[] = [];
      const allScreenshots: string[] = [];

      if (r?.video) videos.push(r.video);
      const shots: any[] = (r?.screenshots as any[]) || [];
      for (const s of shots) {
        if (s?.path) allScreenshots.push(s.path);
      }

      // Skip if there are no artifacts to upload at all
      if (videos.length === 0 && allScreenshots.length === 0) return;

      const token = process.env.QASE_API_TOKEN;
      const runId = Number(process.env.QASE_TESTOPS_RUN_ID);
      const projectCode = (config?.reporterOptions?.cypressQaseReporterReporterOptions?.testops?.project || process.env.QASE_PROJECT || '').toString();
      if (!token || !runId || !projectCode) {
        console.log('[Qase] after:spec: missing token/runId/project; skipping upload');

        return;
      }

      // Per-case mapping
      const shotsByCase = mapScreenshotsByCaseId(allScreenshots);
      const caseIds = Array.from(shotsByCase.keys());
      if (caseIds.length === 0) {
        console.log('[Qase] after:spec: no Qase IDs parsed from spec artifacts; skipping upload');

        return;
      }

      // Minimal health log
      console.log(`[Qase] after:spec: videos=${ videos.length } screenshots=${ allScreenshots.length } caseIds=${ caseIds.join(',') || 'none' }`);

      // Wait videos to be ready
      for (const v of videos) await waitForReady(v).catch(() => {});

      const attachAllScreenshots = !!config.env?.qaseAttachAllScreenshots || process.env.QASE_ATTACH_ALL_SCREENSHOTS === 'true';

      for (const caseId of caseIds) {
        const caseShotsAll = shotsByCase.get(caseId) || [];
        const caseShots = attachAllScreenshots ? caseShotsAll : caseShotsAll.filter((p) => p.toLowerCase().includes('(failed)'));

        const filesForUpload: any[] = [];
        const attachVideoOnPasses = config.env?.qaseAttachVideoOnPasses === true || process.env.QASE_ATTACH_VIDEO_ON_PASSES === 'true';
        const hasCaseFailures = caseShots.some((p) => p.toLowerCase().includes('(failed)')) || (r?.stats?.failures || 0) > 0;

        // Attach the spec video only for failing cases (or if explicitly allowed for passes)
        if (hasCaseFailures || attachVideoOnPasses) {
          for (const v of Array.from(new Set(videos))) {
            try {
              if (fs.existsSync(v)) {
                filesForUpload.push({ name: path.basename(v), value: fs.createReadStream(v) });
              }
            } catch {}
          }
        }
        // Case-specific screenshots
        for (const s of Array.from(new Set(caseShots))) {
          try {
            if (fs.existsSync(s)) {
              filesForUpload.push({ name: path.basename(s), value: fs.createReadStream(s) });
            }
          } catch {}
        }

        if (!filesForUpload.length) {
          console.log(`[Qase] after:spec: no files to attach for case ${ caseId }`);
          continue;
        }

        const status: 'passed' | 'failed' = hasCaseFailures ? 'failed' : 'passed';

        console.log(`[Qase] uploading ${ filesForUpload.length } file(s) for case ${ caseId }`);
        await uploadFilesForCase({
          token,
          projectCode,
          runId,
          caseId,
          files: filesForUpload,
          status
        });
      }
    } catch (e) {
      console.log('[Qase] after:spec error:', e?.message || e);
    }
  });
}

export default { registerQaseArtifacts };
