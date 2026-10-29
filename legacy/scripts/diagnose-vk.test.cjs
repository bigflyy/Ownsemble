'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const {collectDiagnostics, summarizeDiagnostics} = require('./diagnose-vk.cjs');

test('collection requests only a fresh passive report, without invoking Play or sync', async () => {
  // Keep all simulated app files inside an isolated generated directory.
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'ownsemble-report-'));
  try {
    // Reject a previous report until the application acknowledges this request's nonce.
    await fs.writeFile(path.join(directory, 'diagnostics-report.json'), JSON.stringify({
      schema_version: 1, report_id: 'old-report', platform: 'windows', failures: [], events: [],
    }));
    // Model the application's fixed control poll without creating any browser/session files.
    const simulatedApp = setInterval(async () => {
      try {
        // Read the generated command and acknowledge exactly that safe operation.
        const command = JSON.parse(await fs.readFile(path.join(directory, 'control.json'), 'utf8'));
        assert.deepEqual(Object.keys(command).sort(), ['command', 'nonce']);
        assert.equal(command.command, 'write-diagnostics');
        clearInterval(simulatedApp);
        await fs.writeFile(path.join(directory, 'diagnostics-report.json'), JSON.stringify({
          schema_version: 1, report_id: command.nonce, platform: 'windows',
          build_revision: 'abcdef1', events: [], failures: [{area: 'cdn_destination', code: 403}],
        }));
      } catch (error) {
        // Ignore only the short interval before the generated control file appears.
        if (error.code !== 'ENOENT') throw error;
      }
    }, 5);
    try {
      // Use a short fixture deadline instead of waiting for a real application process.
      const report = await collectDiagnostics(directory, {timeoutMs: 1000, intervalMs: 10});
      assert.equal(report.collected, true);
      assert.equal(report.latest_failure.area, 'cdn_destination');
      assert.equal(report.latest_failure.code, 403);
      assert.deepEqual((await fs.readdir(directory)).sort(), ['control.json', 'diagnostics-report.json']);
    } finally {
      clearInterval(simulatedApp);
    }
  } finally {
    await fs.rm(directory, {recursive: true, force: true});
  }
});

test('an absent app produces a bounded failure instead of reading stale evidence', async () => {
  // Model a stopped application using generated report-only files.
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'ownsemble-report-timeout-'));
  try {
    await assert.rejects(collectDiagnostics(directory, {timeoutMs: 40, intervalMs: 5}),
      {message: 'diagnostics_app_not_responding'});
  } finally {
    await fs.rm(directory, {recursive: true, force: true});
  }
});

test('terminal summary excludes arbitrary report strings and account-looking values', () => {
  // Treat even a report file as untrusted when selecting terminal output.
  const summary = summarizeDiagnostics({schema_version: 1, platform: 'private-machine',
    build_revision: 'private-build', adapter_sha256: 'private-digest',
    title: 'Private title', events: [{stage: 'runtime_context', private_signin_active: true,
      url: 'https://private.example/temporary', userId: 123456789}],
    failures: [{area: 'private-area', category: 'Private category', code: 987654321}],
  });
  assert.equal(summary.private_signin_active, true);
  assert.equal(summary.latest_failure.area, 'unclassified');
  assert.equal(JSON.stringify(summary).includes('private.example'), false);
  assert.equal(JSON.stringify(summary).includes('Private'), false);
  assert.equal(JSON.stringify(summary).includes('987654321'), false);
});
