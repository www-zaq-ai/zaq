const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { test } = require('node:test');
const {
  proposeVersion, reserveVersion, stampMixVersion, validateLedger,
  verifyIndex, revisionAnnotation, versionAnnotation,
} = require('./candidate.cjs');
const { expiredCandidates, protectReferencedVersions } = require('./cleanup.cjs');

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

const candidate = { version: '0.20.0-rc.1', sha: 'a'.repeat(40) };
const descriptor = (os, architecture, number) => ({
  digest: `sha256:${String(number).repeat(64)}`, platform: { os, architecture },
});
const index = {
  mediaType: 'application/vnd.oci.image.index.v1+json',
  annotations: { [revisionAnnotation]: candidate.sha, [versionAnnotation]: candidate.version },
  manifests: [
    descriptor('linux', 'amd64', 1),
    { ...descriptor('unknown', 'unknown', 2), annotations: { 'vnd.docker.reference.type': 'attestation-manifest' } },
    descriptor('linux', 'arm64', 3),
  ],
};

test('an index has exactly one runtime per native architecture, plus optional attestations', () => {
  assert.doesNotThrow(() => verifyIndex(index, candidate));
  assert.throws(() => verifyIndex({ ...index, manifests: index.manifests.slice(0, 2) }), /architecture/);
  assert.throws(() => verifyIndex({ ...index, manifests: [...index.manifests, descriptor('linux', 'amd64', 4)] }), /architecture/);
});

test('candidate verification rejects mismatched SHA or version', () => {
  assert.throws(() => verifyIndex(index, { ...candidate, sha: 'b'.repeat(40) }), /reservation/);
  assert.throws(() => verifyIndex(index, { ...candidate, version: '0.20.0-rc.2' }), /reservation/);
});

const day = 24 * 60 * 60 * 1000;
const now = Date.parse('2026-11-18T12:00:00Z');
const version = (id, tag, age, aliases = []) => ({
  id,
  name: `sha256:${id.toString(16).padStart(64, '0')}`,
  created_at: new Date(now - age * day).toISOString(),
  metadata: { container: { tags: [tag, ...aliases] } },
});

test('the newest three are retained independently of age and per channel, across base versions', () => {
  const rcs = [version(1, 'v0.20.0-rc.1', 8), version(2, 'v0.19.2-rc.9', 9),
    version(3, 'v0.19.2-rc.8', 10), version(4, 'v0.19.2-rc.7', 11)];
  const betas = [version(5, 'v0.20.0-beta.3', 12), version(6, 'v0.20.0-beta.2', 13),
    version(7, 'v0.20.0-beta.1', 14), version(8, 'v0.19.2-beta.1', 15)];
  assert.deepEqual(expiredCandidates([...betas.reverse(), ...rcs], now).map(row => row.id), [4, 8]);
});

test('seven days is inclusive; one millisecond older is eligible outside the newest three', () => {
  const rcs = [version(1, 'v0.20.0-rc.1', 1), version(2, 'v0.19.2-rc.9', 2),
    version(3, 'v0.19.2-rc.8', 3), version(4, 'v0.19.2-rc.7', 7),
    version(5, 'v0.19.2-rc.6', 7 + 1 / day), version(6, 'v0.19.2-rc.5', 10, ['rc']),
    version(7, 'v0.19.1', 50), version(8, 'prerelease-ledger', 50)];
  assert.deepEqual(expiredCandidates(rcs, now).map(row => row.id), [5]);
});

test('cleanup stops rather than guessing retention ordering when a publication date is unknown', () => {
  const row = version(1, 'v0.19.2-beta.1', 10);
  assert.throws(() => expiredCandidates([{ ...row, created_at: undefined }], now), /publication date/);
});

test('the live registry graph protects stale API aliases, shared child manifests and attestations', () => {
  const expired = [version(1, 'v0.19.2-rc.1', 10), version(2, 'v0.19.2-rc.2', 10),
    version(3, 'v0.19.2-rc.3', 10), version(4, 'v0.19.2-rc.4', 10)];
  const retained = version(5, 'v0.20.0-rc.1', 1).name;
  const attestation = version(6, 'attestation', 1).name;
  const remoteTags = new Map([['v0.19.2-rc.1', expired[0].name], ['rc', expired[0].name],
    ['v0.19.2-rc.2', expired[1].name], ['v0.19.2-rc.3', expired[2].name],
    ['v0.19.2-rc.4', expired[3].name], ['v0.20.0-rc.1', retained]]);
  const manifests = new Map([
    [retained, { manifests: [{ digest: expired[1].name }, { digest: attestation }] }],
    [attestation, { subject: { digest: expired[2].name } }],
  ]);
  const eligible = protectReferencedVersions(expired, remoteTags, digest => manifests.get(digest) ?? {});
  assert.deepEqual(eligible.map(row => row.id), [4]);
});
