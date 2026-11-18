const { execFileSync } = require('node:child_process');
const { mkdtempSync, readFileSync, rmSync, writeFileSync } = require('node:fs');
const { tmpdir } = require('node:os');
const { join } = require('node:path');
const { candidateVersionPattern, digestPattern, validateLedger } = require('./versions.cjs');

const ledgerTag = 'prerelease-ledger';
const ledgerFile = 'ledger.json';
const ledgerMediaType = 'application/vnd.zaq.prerelease-ledger.v1+json';
const imageIndexTypes = new Set([
  'application/vnd.oci.image.index.v1+json',
  'application/vnd.docker.distribution.manifest.list.v2+json',
]);
const revisionAnnotation = 'org.opencontainers.image.revision';
const versionAnnotation = 'org.opencontainers.image.version';

function oras(args, options = {}) {
  return execFileSync('oras', args, { encoding: 'utf8', stdio: ['pipe', 'pipe', 'inherit'], ...options });
}

function withLedgerDirectory(operation) {
  const directory = mkdtempSync(join(tmpdir(), 'zaq-prerelease-'));
  try {
    return operation(directory);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

function listTags(image) {
  return new Set(oras(['repo', 'tags', image]).trim().split(/\s+/).filter(Boolean));
}

function loadLedger(image, tags) {
  if (!tags.has(ledgerTag)) {
    if ([...tags].some(tag => tag.startsWith('v') && candidateVersionPattern.test(tag.slice(1)))) {
      throw new Error('Candidate tags exist but the prerelease ledger is missing');
    }
    return { schema: 1, candidates: [] };
  }
  return withLedgerDirectory(directory => {
    oras(['pull', `${image}:${ledgerTag}`, '--output', directory]);
    return validateLedger(JSON.parse(readFileSync(join(directory, ledgerFile), 'utf8')));
  });
}

function saveLedger(image, ledger) {
  withLedgerDirectory(directory => {
    writeFileSync(join(directory, ledgerFile), JSON.stringify(validateLedger(ledger)));
    oras(['push', '--artifact-type', ledgerMediaType, `${image}:${ledgerTag}`, `${ledgerFile}:${ledgerMediaType}`], { cwd: directory });
  });
}

function verifyIndex(index, candidate) {
  if (!imageIndexTypes.has(index.mediaType) || !Array.isArray(index.manifests) ||
      index.manifests.some(child => !digestPattern.test(child.digest))) {
    throw new Error('Expected a valid multi-platform image index');
  }
  const platforms = index.manifests
    .filter(child => child.annotations?.['vnd.docker.reference.type'] !== 'attestation-manifest')
    .map(child => `${child.platform?.os}/${child.platform?.architecture}`).sort();
  if (platforms.join(',') !== 'linux/amd64,linux/arm64') {
    throw new Error(`Expected one image for each native architecture, got ${platforms.join(', ')}`);
  }
  if (candidate && (index.annotations?.[revisionAnnotation] !== candidate.sha ||
      index.annotations?.[versionAnnotation] !== candidate.version)) {
    throw new Error('Candidate image index does not match its SHA and version reservation');
  }
}

function fetchManifest(image, digest) {
  return JSON.parse(oras(['manifest', 'fetch', `${image}@${digest}`]));
}

function resolveTag(image, tag) {
  const { digest } = JSON.parse(oras(['manifest', 'fetch', '--descriptor', `${image}:${tag}`]));
  if (!digestPattern.test(digest)) throw new Error(`Invalid registry digest for ${tag}`);
  return digest;
}

function verifyPublishedCandidate(image, candidate) {
  const digest = resolveTag(image, `v${candidate.version}`);
  if (candidate.digest && candidate.digest !== digest) {
    throw new Error(`The existing tag v${candidate.version} does not match the reservation`);
  }
  verifyIndex(fetchManifest(image, digest), candidate);
  return digest;
}

module.exports = {
  oras, listTags, loadLedger, saveLedger, fetchManifest, resolveTag, verifyIndex, verifyPublishedCandidate,
  revisionAnnotation, versionAnnotation,
};
