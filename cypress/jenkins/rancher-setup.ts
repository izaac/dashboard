/**
 * Rancher post-deploy setup: creates standard_user, assigns roles,
 * and detects the dashboard branch from server settings.
 *
 * Usage:
 *   node --experimental-strip-types cypress/jenkins/rancher-setup.ts \
 *     --host <rancher-host> --password <admin-password>
 *
 * Outputs (to stdout, one per line):
 *   BRANCH_FROM_RANCHER=<branch>
 *
 * Requires: Node.js 22+ (for --experimental-strip-types)
 */

// Skip TLS verification for self-signed Rancher certs (same as curl -k)
process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';

interface ApiResponse {
  id?: string;
  token?: string;
  data?: Array<{ id?: string; default?: string; value?: string }>;
  [key: string]: unknown;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function parseArgs(): { host: string; password: string; rancherPassword: string } {
  const args = process.argv.slice(2);
  let host = '';
  let password = '';
  let rancherPassword = '';

  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--host' && args[i + 1]) {
      host = args[++i];
    }
    if (args[i] === '--password' && args[i + 1]) {
      password = args[++i];
    }
    if (args[i] === '--rancher-password' && args[i + 1]) {
      rancherPassword = args[++i];
    }
  }

  if (!host || !password) {
    console.error('Usage: rancher-setup.ts --host <host> --password <password> [--rancher-password <pw>]');
    process.exit(1);
  }

  return { host, password, rancherPassword: rancherPassword || password };
}

async function api(
  url: string,
  options: { method?: string; body?: unknown; token?: string; accept?: string } = {}
): Promise<ApiResponse> {
  const { method = 'GET', body, token, accept = 'application/json' } = options;
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    Accept:         accept,
  };

  if (token) {
    headers['Authorization'] = `Bearer ${token}`;
  }

  const response = await fetch(url, {
    method,
    headers,
    body: body ? JSON.stringify(body) : undefined,
  });

  const text = await response.text();

  if (!response.ok && response.status !== 409) {
    throw new Error(`${method} ${url} → ${response.status}: ${text}`);
  }

  try {
    return JSON.parse(text) as ApiResponse;
  } catch {
    return { _raw: text } as unknown as ApiResponse;
  }
}

function log(msg: string): void {
  console.error(`[rancher_setup] ${msg}`);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main(): Promise<void> {
  const { host, password, rancherPassword } = parseArgs();
  const baseUrl = `https://${host}`;

  // 1. Login as admin
  log('Logging in as admin...');
  const loginResp = await api(`${baseUrl}/v3-public/localProviders/local?action=login`, {
    method: 'POST',
    body:   { username: 'admin', password },
  });

  const token = loginResp.token;

  if (!token) {
    throw new Error(`Login failed — no token in response: ${JSON.stringify(loginResp)}`);
  }
  log(`Token obtained: yes`);

  // 2. Create standard_user
  log('Creating standard_user...');
  let userId: string | undefined;

  try {
    const userResp = await api(`${baseUrl}/v3/users`, {
      method: 'POST',
      token,
      body:   {
        enabled:            true,
        mustChangePassword: false,
        password:           rancherPassword,
        username:           'standard_user',
      },
    });
    userId = userResp.id;
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);

    // 409 = user already exists, or the error might contain "already exists"
    if (message.includes('409') || message.includes('already exists')) {
      log('standard_user already exists, looking up ID...');
      const existing = await api(`${baseUrl}/v3/users?username=standard_user`, { token }) as { data?: Array<{ id: string }> };
      userId = existing.data?.[0]?.id;
    } else {
      throw err;
    }
  }

  if (!userId) {
    throw new Error('Failed to create or find standard_user');
  }
  log(`user_id: ${userId}`);

  // 3. Create globalRoleBinding
  log('Creating globalRoleBinding...');
  try {
    await api(`${baseUrl}/v3/globalrolebindings`, {
      method: 'POST',
      token,
      body:   { globalRoleId: 'user', type: 'globalRoleBinding', userId },
    });
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);

    if (message.includes('409') || message.includes('already exists')) {
      log('globalRoleBinding already exists, skipping');
    } else {
      throw err;
    }
  }

  // 4. Get Default project and create projectRoleTemplateBinding
  log('Getting Default project...');
  const projectsResp = await api(
    `${baseUrl}/v3/projects?name=Default&clusterId=local`,
    { token }
  ) as { data?: Array<{ id: string }> };
  const projectId = projectsResp.data?.[0]?.id;
  log(`project_id: ${projectId}`);

  if (projectId) {
    log('Creating projectRoleTemplateBinding...');
    try {
      await api(`${baseUrl}/v3/projectroletemplatebindings`, {
        method: 'POST',
        token,
        body:   {
          type:           'projectroletemplatebinding',
          roleTemplateId: 'project-member',
          projectId,
          userId,
        },
      });
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);

      if (message.includes('409') || message.includes('already exists')) {
        log('projectRoleTemplateBinding already exists, skipping');
      } else {
        throw err;
      }
    }
  }

  // 5. Verify standard_user login
  log('Verifying standard_user can log in...');
  const verifyResp = await api(`${baseUrl}/v3-public/localProviders/local?action=login`, {
    method: 'POST',
    body:   { username: 'standard_user', password: rancherPassword },
  });
  log(`standard_user login: ${verifyResp.token ? 'OK' : 'FAILED'}`);

  // 6. Detect dashboard branch from Rancher settings
  log('Detecting dashboard branch from Rancher settings...');
  let branch = '';

  try {
    const settingsResp = await api(`${baseUrl}/v1/management.cattle.io.settings`, {
      token,
    }) as { data?: Array<{ id?: string; default?: string; value?: string }> };

    const items = settingsResp.data || [];

    // Look for ui-dashboard-index setting — its default contains the release branch URL
    const uiSetting = items.find((s) => s.id === 'ui-dashboard-index');
    const settingValue = uiSetting?.default || uiSetting?.value || '';

    // Extract release branch: e.g. "https://releases.rancher.com/dashboard/release-2.12/index.html"
    const releaseMatch = settingValue.match(/\/dashboard\/(release-[\d.]+)\//);

    if (releaseMatch) {
      branch = releaseMatch[1];
    }
  } catch {
    log('Could not read settings API, will check /dashboard/about...');
  }

  if (!branch) {
    // Fallback: check if this is a "latest" (master) build
    try {
      const aboutResp = await fetch(`${baseUrl}/dashboard/about`, {
        headers: { Accept: 'text/html', Authorization: `Bearer ${token}` },
      });
      const html = await aboutResp.text();

      if (html.includes('dashboard/latest/')) {
        branch = 'master';
      }
    } catch {
      // ignore
    }
  }

  if (!branch) {
    log('ERROR: Could not determine dashboard branch from Rancher');
    process.exit(1);
  }

  log(`Detected branch: ${branch}`);

  // Output for bash consumption (stdout only — all logs go to stderr)
  console.log(`BRANCH_FROM_RANCHER=${branch}`);
}

main().catch((err: unknown) => {
  const message = err instanceof Error ? err.message : String(err);

  console.error(`[rancher_setup] FATAL: ${message}`);
  process.exit(1);
});
