const assert = require('node:assert/strict');
const { test } = require('node:test');
const { verifyIndex, revisionAnnotation, versionAnnotation } = require('./registry.cjs');

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
