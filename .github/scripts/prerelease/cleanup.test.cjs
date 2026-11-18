const assert = require('node:assert/strict');
const { test } = require('node:test');
const { expiredCandidates, protectReferencedVersions } = require('./cleanup.cjs');

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
