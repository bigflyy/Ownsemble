'use strict';
const fs = require('node:fs/promises');
const path = require('node:path');
const {randomUUID} = require('node:crypto');

// Accept fixed investigation areas rather than free-form messages from a report.
const AREAS = new Set(['cancelled', 'cdn_destination', 'connection_or_private_signin',
  'provider_restriction', 'recording_identity', 'media_transport', 'playlist_or_segment_format',
  'local_cache', 'source_resolution', 'native_playback_or_integrity', 'page_or_adapter_contract',
  'unclassified']);

/** Select only fixed public labels, bounded codes and booleans for terminal output. */
function summarizeDiagnostics(report) {
  // Unknown labels can contain machine/account data, so replace them rather than printing them.
  const summary = {collected: true, schema_version: 1,
    report: '.local/ownsemble/diagnostics-report.json',
    platform: ['windows','linux','android','ios','macos'].includes(report.platform) ? report.platform : 'unknown',
    build_revision: /^[a-f0-9]{7,40}(?:-dirty)?$/.test(report.build_revision || '') ? report.build_revision : 'unlabelled'};
  // A bundled source digest identifies adapter changes without exposing any media address.
  if (/^[a-f0-9]{64}$/.test(report.adapter_sha256 || '')) summary.adapter_sha256 = report.adapter_sha256;
  // Find the app's latest passive context without copying arbitrary event contents.
  const context = Array.isArray(report.events) ? report.events.filter(event => event?.stage === 'runtime_context').at(-1) : undefined;
  for (const key of ['private_signin_active', 'offline', 'provider_connected', 'loading', 'playing', 'buffering', 'cached']) {
    // Accept boolean state only, never page strings or numeric identifiers.
    if (typeof context?.[key] === 'boolean') summary[key] = context[key];
  }
  // Keep an old failure clearly separate from the current application state.
  const failure = Array.isArray(report.failures) ? report.failures.at(-1) : undefined;
  if (failure && typeof failure === 'object') {
    summary.latest_failure = {area: AREAS.has(failure.area) ? failure.area : 'unclassified'};
    // HTTP and common OS status codes fit this bound; larger values are not useful here.
    if (Number.isInteger(failure.code) && Math.abs(failure.code) <= 65535) summary.latest_failure.code = failure.code;
  }
  return summary;
}

/** Request existing evidence without asking the application to connect, scan or play. */
async function collectDiagnostics(directory, {timeoutMs = 8000, intervalMs = 100} = {}) {
  // Use a fresh non-authentication nonce to reject reports from earlier requests.
  const nonce = randomUUID();
  // Restrict all file access to the two fixed app-owned control/report filenames.
  const control = path.join(directory, 'control.json');
  // Never enumerate files, inspect profiles or read other existing app reports.
  const reportFile = path.join(directory, 'diagnostics-report.json');
  await fs.mkdir(directory, {recursive: true});
  await fs.writeFile(control + '.tmp', JSON.stringify({command: 'write-diagnostics', nonce}));
  await fs.rename(control + '.tmp', control);
  // Bound collection when the application is stopped or its local controls are disabled.
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      // Reject oversized reports before loading their contents into memory.
      const metadata = await fs.stat(reportFile);
      if (metadata.size <= 204800) {
        // Parse only the app-produced safe report, then select a second strict terminal summary.
        const report = JSON.parse(await fs.readFile(reportFile, 'utf8'));
        if (report.schema_version === 1 && report.report_id === nonce) return summarizeDiagnostics(report);
      }
    } catch (error) {
      // A missing or concurrently replaced report can be retried within the same deadline.
      if (error.code !== 'ENOENT' && !(error instanceof SyntaxError)) throw new Error('diagnostics_report_unreadable');
    }
    await new Promise(resolve => setTimeout(resolve, intervalMs));
  }
  throw new Error('diagnostics_app_not_responding');
}

module.exports = {collectDiagnostics, summarizeDiagnostics};

// Expose a single fixed checkout command; arbitrary directories/options are test-only APIs.
if (require.main === module) {
  // Accept no paths or caller-supplied browser actions from the command line.
  if (process.argv.length !== 2) {
    console.error('Use node scripts/diagnose-vk.cjs with Ownsemble open.');
    process.exitCode = 2;
  } else {
    collectDiagnostics(path.resolve(__dirname, '../.local/ownsemble'))
      .then(report => console.log(JSON.stringify(report, null, 2)))
      .catch(() => {console.error('Diagnostic collection failed; the app may be stopped or unresponsive.'); process.exitCode = 1;});
  }
}
