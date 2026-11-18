const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { test } = require('node:test');
const { proposeVersion, reserveVersion, stampMixVersion, validateLedger } = require('./versions.cjs');

const config = JSON.parse(readFileSync(`${__dirname}/../../../release-please-config.json`));
const manifest = { '.': '0.19.1' };
const releaseSha = 'a'.repeat(40);
const sourceSha = 'b'.repeat(40);
const laterSha = 'c'.repeat(40);
const digest = `sha256:${'1'.repeat(64)}`;
const logger = { debug() {}, info() {}, warn() {}, error() {} };

function githubHistory(messages, { boundary = releaseSha, includeBoundary = true } = {}) {
  return {
    repository: { owner: 'example', repo: 'app', defaultBranch: 'main' },
    async *releaseIterator() { yield { tagName: 'v0.19.1', sha: releaseSha }; },
    async *mergeCommitIterator(branch) {
      assert.equal(branch, 'work/branch');
      for (const [index, message] of messages.entries()) {
        yield { sha: index === 0 ? sourceSha : laterSha, message, files: ['mix.exs'] };
      }
      if (includeBoundary) yield { sha: boundary, message: 'fix: already released', files: ['mix.exs'] };
    },
  };
}

function proposal(messages, options = {}) {
  const boundary = options.boundary ?? releaseSha;
  return proposeVersion(githubHistory(messages, options), {
    branch: 'work/branch', sourceSha: messages.length ? sourceSha : boundary,
    boundary, config, manifest, logger,
  });
}

test('the repository release-please configuration controls patch, minor and no-proposal cases', async () => {
  assert.equal(await proposal(['fix: repair TLS']), '0.19.2');
  assert.equal(await proposal(['fix: repair TLS', 'feat: add widget']), '0.20.0');
  assert.equal(await proposal(['chore: housekeeping']), undefined);
  assert.equal(await proposal([]), undefined);
});

test('a branch forked before the stable tag stops at the merge base, not at the start of history', async () => {
  assert.equal(await proposal(['fix: branch change'], { boundary: 'd'.repeat(40) }), '0.19.2');
});

test('a missing history boundary fails closed rather than proposing from incomplete history', async () => {
  await assert.rejects(proposal(['fix: branch change'], { includeBoundary: false }), /boundary/);
});

test('a source branch moving before history is read fails closed', async () => {
  await assert.rejects(proposeVersion(githubHistory(['fix: branch change']), {
    branch: 'work/branch', sourceSha: laterSha, boundary: releaseSha, config, manifest, logger,
  }), /moved/);
});

test('retry keeps a reservation; channel and base each start at one', () => {
  const ledger = { schema: 1, candidates: [] };
  const rc = reserveVersion(ledger, '0.19.2', 'rc', sourceSha);
  assert.equal(rc.version, '0.19.2-rc.1');
  assert.equal(reserveVersion(ledger, '0.19.2', 'rc', sourceSha), rc);
  assert.equal(reserveVersion(ledger, '0.19.2', 'beta', sourceSha).version, '0.19.2-beta.1');
  assert.equal(reserveVersion(ledger, '0.20.0', 'rc', sourceSha).version, '0.20.0-rc.1');
});

test('candidate numbers increase even when old images have been pruned', () => {
  const ledger = { schema: 1, candidates: [] };
  for (let number = 1; number <= 12; number++) {
    const sha = number.toString(16).padStart(40, '0');
    const candidate = reserveVersion(ledger, '0.19.2', 'rc', sha);
    assert.equal(candidate.version, `0.19.2-rc.${number}`);
    candidate.digest = digest;
    validateLedger(ledger);
  }
});

test('a malformed or conflicting ledger cannot allocate a tag', () => {
  assert.throws(() => validateLedger({ schema: 1, candidates: [{ version: '0.19.2', sha: sourceSha }] }));
  const entry = { version: '0.19.2-rc.1', sha: sourceSha };
  assert.throws(() => validateLedger({ schema: 1, candidates: [entry, { ...entry, sha: laterSha }] }));
});

test('the Elixir updater stamps the version in the checkout without changing other fields', () => {
  const mix = 'def project, do: [app: :zaq, version: "0.19.1", elixir: "~> 1.20"]';
  assert.equal(stampMixVersion(mix, '0.19.2-beta.1'), mix.replace('0.19.1', '0.19.2-beta.1'));
  assert.throws(() => stampMixVersion('def project, do: []', '0.19.2-beta.1'));
});
