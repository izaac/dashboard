/* eslint-disable no-console */
import { defineConfig } from 'cypress';
import { registerQaseArtifacts } from './qaseArtifactsHelper';
import websocketTasks from '../../cypress/support/utils/webSocket-utils';
import path from 'path';

// eslint-disable-next-line @typescript-eslint/no-var-requires
const { removeDirectory } = require('cypress-delete-downloads-folder');

// Required for env vars to be available in cypress
require('dotenv').config();

/**
 * VARIABLES
 */

const testDirs = [
  'cypress/e2e/tests/priority/**/*.spec.ts',
  'cypress/e2e/tests/components/**/*.spec.ts',
  'cypress/e2e/tests/setup/**/*.spec.ts',
  'cypress/e2e/tests/pages/**/*.spec.ts',
  'cypress/e2e/tests/navigation/**/*.spec.ts',
  'cypress/e2e/tests/global-ui/**/*.spec.ts',
  'cypress/e2e/tests/features/**/*.spec.ts',
  'cypress/e2e/tests/extensions/**/*.spec.ts'
];
const skipSetup = process.env.TEST_SKIP?.includes('setup');
const baseUrl = (process.env.TEST_BASE_URL || 'https://localhost:8005').replace(/\/$/, '');
const DEFAULT_USERNAME = 'admin';
const username = process.env.TEST_USERNAME || DEFAULT_USERNAME;
const apiUrl = process.env.API || (baseUrl.endsWith('/dashboard') ? baseUrl.split('/').slice(0, -1).join('/') : baseUrl);

// // Reset Qase run ID variables if QASE_FORCE_NEW_RUN is true
// if (process.env.QASE_FORCE_NEW_RUN === 'true') {
//   delete process.env.QASE_TESTOPS_RUN_ID;
//   delete process.env.QASE_RUN_ID;
//   console.log('🔄 Qase run ID variables reset for new run');
// }

/**
 * LOGS:
 * Summary of the environment variables that we have detected (or are goin  g ot use)
 * We won't show any passwords
 */
console.log('E2E Test Configuration');
console.log('');
console.log(`    Username: ${ username }`);

if (!process.env.CATTLE_BOOTSTRAP_PASSWORD && !process.env.TEST_PASSWORD) {
  console.log(' ❌ You must provide either CATTLE_BOOTSTRAP_PASSWORD or TEST_PASSWORD');
}
if (process.env.CATTLE_BOOTSTRAP_PASSWORD && process.env.TEST_PASSWORD) {
  console.log(' ❗ If both CATTLE_BOOTSTRAP_PASSWORD and TEST_PASSWORD are provided, the first will be used');
}
if (!skipSetup && !process.env.CATTLE_BOOTSTRAP_PASSWORD) {
  console.log(' ❌ You must provide CATTLE_BOOTSTRAP_PASSWORD when running setup tests');
}
if (skipSetup && !process.env.TEST_PASSWORD) {
  console.log(' ❌ You must provide TEST_PASSWORD when running the tests without the setup tests');
}

console.log(`    Setup tests will ${ skipSetup ? 'NOT' : '' } be run`);
console.log(`    Dashboard URL: ${ baseUrl }`);
console.log(`    Rancher API URL: ${ apiUrl }`);

// Check API - sometimes in dev, you might have API set to a different system to the base url - this won't work
// as the login cookie will be for the base url and any API requests will fail as not authenticated
if (apiUrl && !baseUrl.startsWith(apiUrl)) {
  console.log('\n ❗ API variable is different to TEST_BASE_URL - tests may fail due to authentication issues');
}

console.log(`QASE_API_TOKEN is ${ process.env.QASE_API_TOKEN ? 'defined' : 'undefined' }`);
console.log('');

/**
 * CONFIGURATION
 */
export default defineConfig({
  projectId:             process.env.TEST_PROJECT_ID,
  defaultCommandTimeout: process.env.TEST_TIMEOUT ? +process.env.TEST_TIMEOUT : 10000,
  trashAssetsBeforeRuns: true,
  chromeWebSecurity:     false,
  retries:               {
    runMode:  2,
    openMode: 0
  },
  env: {
    grepFilterSpecs:     true,
    grepOmitFiltered:    true,
    baseUrl,
    api:                 apiUrl,
    username,
    password:            process.env.CATTLE_BOOTSTRAP_PASSWORD || process.env.TEST_PASSWORD,
    bootstrapPassword:   process.env.CATTLE_BOOTSTRAP_PASSWORD,
    grepTags:            process.env.GREP_TAGS,
    // the below env vars are only available to tests that run in Jenkins
    awsAccessKey:        process.env.AWS_ACCESS_KEY_ID,
    awsSecretKey:        process.env.AWS_SECRET_ACCESS_KEY,
    azureSubscriptionId: process.env.AZURE_AKS_SUBSCRIPTION_ID,
    azureClientId:       process.env.AZURE_CLIENT_ID,
    azureClientSecret:   process.env.AZURE_CLIENT_SECRET,
    customNodeIp:        process.env.CUSTOM_NODE_IP,
    customNodeKey:       process.env.CUSTOM_NODE_KEY,
    accessibility:       !!process.env.TEST_A11Y, // Are we running accessibility tests?
    a11yFolder:          path.join('.', 'cypress', 'accessibility'),
    gkeServiceAccount:   process.env.GKE_SERVICE_ACCOUNT,
    customNodeIpRke1:    process.env.CUSTOM_NODE_IP_RKE1,
    customNodeKeyRke1:   process.env.CUSTOM_NODE_KEY_RKE1
  },
  // Jenkins reporters configuration jUnit and Qase
  reporter: 'cypress-multi-reporters',

  reporterOptions: {
    // Re-enable Qase + JUnit multi-reporter
    reporterEnabled: 'cypress-qase-reporter, mocha-junit-reporter',

    // Options for Qase reporter (v2 format)
    // The key MUST be 'cypressQaseReporterReporterOptions'
    cypressQaseReporterReporterOptions: {
      mode:    'testops',
      debug:   false,
      logging: false,
      testops: {
        api:               { token: process.env.QASE_API_TOKEN },
        project:           'SANDBOX',
        uploadAttachments: true,
        run:               {
          title:    `Cypress Automated Run - ${ new Date().toISOString() }`,
          complete: true,
        },
      },
    },

    // Options for mocha-junit-reporter
    mochaJunitReporterReporterOptions: {
      mochaFile:   'cypress/reports/junit/results-[hash].xml',
      toConsole:   false,
      attachments: true
    },
  },
  e2e: {
    setupNodeEvents(on, config) {
      // Toggle artifact debug mode (screenshots/videos) via --env artifactsDebug=true
      const artifactsDebug = !!config.env?.artifactsDebug || process.env.ARTIFACTS_DEBUG === 'true';

      // Prefer dynamic control of video based on debug flag
      config.video = !!artifactsDebug;

      // Clear Qase reporter persisted state so it doesn't force QASE_MODE=off across runs
      try {
        const { StateManager } = require('qase-javascript-commons/dist/state/state');

        StateManager.clearState();
      } catch (e) {
        // ignore
      }
      require('cypress-mochawesome-reporter/plugin')(on);
      require('@cypress/grep/src/plugin')(config);

      // Enable Qase reporter plugin (handles run creation and result publishing)
      try {
        require('cypress-qase-reporter/package.json');
      } catch (e) {
        // ignore
      }
      try {
        const qaseOptions = config.reporterOptions.cypressQaseReporterReporterOptions;

        require('cypress-qase-reporter/plugin')(on, config, qaseOptions);
      } catch (e) {
        console.error('Failed to register Qase reporter plugin:', e?.message || e);
      }
      try {
        require('cypress-qase-reporter/metadata')(on);
      } catch (e) {
        // metadata optional
      }

      // Ensure run gets created; skip if already present
      on('before:run', async() => {
        if (!process.env.QASE_TESTOPS_RUN_ID) {
          try {
            const { beforeRunHook } = require('cypress-qase-reporter/hooks');

            await beforeRunHook(config);
          } catch (e) {
            console.log('Qase beforeRunHook error:', e?.message || e);
          }
        }
      });

      // Register per-spec artifact uploads via helper (per-case mapping + reliable uploads)
      registerQaseArtifacts(on, config);
      on('after:run', async() => {
        if (process.env.QASE_TESTOPS_RUN_ID) {
          try {
            const { afterRunHook } = require('cypress-qase-reporter/hooks');

            await afterRunHook(config);
          } catch (e) {
            console.log('Qase afterRunHook error:', e?.message || e);
          }
        }
      });

      on('task', { removeDirectory });
      websocketTasks(on, config);

      require('cypress-terminal-report/src/installLogsPrinter')(on, {
        outputRoot:           `${ config.projectRoot }/browser-logs/`,
        outputTarget:         { 'out.html': 'html' },
        logToFilesOnAfterRun: true,
        printLogsToConsole:   'never',
        // printLogsToFile:      'always', // default prints on failures
      });

      return config;
    },
    fixturesFolder:               'cypress/e2e/blueprints',
    experimentalSessionAndOrigin: true,
    specPattern:                  testDirs,
    baseUrl
  },
  video:                  false,
  videoCompression:       25,
  videoUploadOnPasses:    false,
  screenshotOnRunFailure: true,
});
