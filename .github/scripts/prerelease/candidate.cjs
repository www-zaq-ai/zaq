const { execFileSync } = require('node:child_process');
const { appendFileSync, lstatSync, mkdtempSync, readFileSync, rmSync, writeFileSync } = require('node:fs');
const { tmpdir } = require('node:os');
const { join } = require('node:path');

const env = process.env;
const configPath = join(__dirname, '../../../release-please-config.json');
const image = `ghcr.io/${env.GITHUB_REPOSITORY?.toLowerCase()}`;

const stableVersionPattern = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;
const candidateVersionPattern = /^((?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*))-(rc|beta)\.([1-9]\d*)$/;
const shaPattern = /^[a-f0-9]{40}$/;
const digestPattern = /^sha256:[a-f0-9]{64}$/;
const ledgerTag = 'prerelease-ledger';
const ledgerFile = 'ledger.json';
const ledgerMediaType = 'application/vnd.zaq.prerelease-ledger.v1+json';
const imageIndexTypes = new Set([
  'application/vnd.oci.image.index.v1+json',
  'application/vnd.docker.distribution.manifest.list.v2+json',
]);
const revisionAnnotation = 'org.opencontainers.image.revision';
const versionAnnotation = 'org.opencontainers.image.version';

async function proposeVersion(github, { branch, sourceSha, boundary, config, manifest, logger }) {
  const { Manifest } = require('release-please');
  const history = Object.create(github);
  let reachedBoundary = false;

  // Use stable policy and baseline even when the selected branch forked before the last release.
  history.getFileJson = async (file, ref) => {
    if (file === 'release-please-config.json') return config;
    if (file === '.release-please-manifest.json') return manifest;
    return github.getFileJson(file, ref);
  };
  history.mergeCommitIterator = async function* (ref, options) {
    let firstCommit = true;
    for await (const commit of github.mergeCommitIterator(ref, options)) {
      if (firstCommit && commit.sha !== sourceSha) throw new Error('Source branch moved during proposal');
      firstCommit = false;
      if (commit.sha === boundary) reachedBoundary = true;
      yield commit;
    }
  };

  const release = await Manifest.fromManifest(history, branch, undefined, undefined, {
    lastReleaseSha: boundary,
    logger,
  });
  const proposals = await release.buildPullRequests();
  if (!reachedBoundary) throw new Error('Release history did not reach the stable ancestry boundary');
  if (proposals.length > 1) throw new Error('Expected one release-please proposal for the root package');
  const version = proposals[0]?.version?.toString();
  if (version && !stableVersionPattern.test(version)) throw new Error(`Expected a stable proposal, got ${version}`);
  return version;
}

function validateLedger(ledger) {
  if (ledger?.schema !== 1 || !Array.isArray(ledger.candidates)) throw new Error('Invalid candidate ledger');
  const versions = new Set();
  const revisions = new Set();
  for (const candidate of ledger.candidates) {
    const match = candidateVersionPattern.exec(candidate.version);
    if (!match || !Number.isSafeInteger(Number(match[3])) || !shaPattern.test(candidate.sha) ||
        (candidate.digest !== undefined && !digestPattern.test(candidate.digest))) {
      throw new Error('Invalid candidate ledger entry');
    }
    const revision = `${match[1]}-${match[2]}:${candidate.sha}`;
    if (versions.has(candidate.version) || revisions.has(revision)) throw new Error('Conflicting candidate ledger entries');
    versions.add(candidate.version);
    revisions.add(revision);
  }
  return ledger;
}

function reserveVersion(ledger, base, channel, sha) {
  const { Version } = require('release-please/build/src/version');
  const { PrereleaseVersioningStrategy } = require('release-please/build/src/versioning-strategies/prerelease');
  validateLedger(ledger);
  if (!stableVersionPattern.test(base) || !['rc', 'beta'].includes(channel) || !shaPattern.test(sha)) {
    throw new Error('Invalid candidate base, channel or source SHA');
  }

  const prefix = `${base}-${channel}.`;
  let latest = `${prefix}0`;
  for (const candidate of ledger.candidates) {
    if (!candidate.version.startsWith(prefix)) continue;
    if (candidate.sha === sha) return candidate;
    if (Number(candidate.version.slice(prefix.length)) > Number(latest.slice(prefix.length))) latest = candidate.version;
  }

  // Seed a new series at .0 so release-please increments only the suffix.
  const strategy = new PrereleaseVersioningStrategy({ prerelease: true });
  const version = strategy.bump(Version.parse(latest), []).toString();
  const candidate = { version, sha };
  ledger.candidates.push(candidate);
  validateLedger(ledger);
  return candidate;
}

function stampMixVersion(content, version) {
  const { Version } = require('release-please/build/src/version');
  const { ElixirMixExs } = require('release-please/build/src/updaters/elixir/elixir-mix-exs');
  if (!candidateVersionPattern.test(version)) throw new Error('Invalid candidate build version');
  const updated = new ElixirMixExs({ version: Version.parse(version) }).updateContent(content);
  if (!updated.includes(`version: "${version}"`)) throw new Error('Could not stamp Mix project version');
  return updated;
}

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

async function githubRequest(path, { method = 'GET', allowMissing = false } = {}) {
  const response = await fetch(`${env.GITHUB_API_URL}${path}`, {
    method,
    headers: {
      Accept: 'application/vnd.github+json',
      Authorization: `Bearer ${env.GH_TOKEN}`,
      'X-GitHub-Api-Version': '2022-11-28',
    },
  });
  if (allowMissing && response.status === 404) return undefined;
  if (!response.ok) throw new Error(`GitHub ${method} ${path}: ${response.status}`);
  if (response.status !== 204) return { body: await response.json(), link: response.headers.get('link') };
}

function repoRequest(path, options) {
  return githubRequest(`/repos/${env.GITHUB_REPOSITORY}${path}`, options);
}

async function branchHead(branch) {
  if (!branch) throw new Error('Select a repository source branch');
  return (await repoRequest(`/git/ref/heads/${encodeURIComponent(branch)}`)).body.object.sha;
}

function setOutput(key, value) {
  appendFileSync(env.GITHUB_OUTPUT, `${key}=${value}\n`);
}

async function prepareCandidate() {
  const { GitHub } = require('release-please');
  const branch = env.SOURCE_BRANCH;
  const sha = await branchHead(branch);
  const channel = env.MODE;
  if (channel === 'rc' && sha !== env.SOURCE_SHA) return console.log('Superseded by a newer main push');

  const release = (await repoRequest('/releases/latest', { allowMissing: true }))?.body;
  if (!release) throw new Error('A published stable GitHub Release is required to build candidates');
  const base = release.tag_name.slice(1);
  if (release.prerelease || release.draft || release.tag_name !== `v${base}` || !stableVersionPattern.test(base)) {
    throw new Error('The latest GitHub Release does not have a stable vMAJOR.MINOR.PATCH tag');
  }
  const stableSha = (await repoRequest(`/commits/${encodeURIComponent(release.tag_name)}`)).body.sha;
  if (sha === stableSha) return console.log('Source is already an official release');
  const boundary = (await repoRequest(`/compare/${stableSha}...${sha}?per_page=1`)).body.merge_base_commit.sha;
  const [owner, repo] = env.GITHUB_REPOSITORY.split('/');
  const github = await GitHub.create({ owner, repo, token: env.GH_TOKEN, defaultBranch: 'main' });
  const versionBase = await proposeVersion(github, {
    branch, sourceSha: sha, boundary, config: JSON.parse(readFileSync(configPath)), manifest: { '.': base },
  });
  if (await branchHead(branch) !== sha) throw new Error('Source branch moved during proposal; dispatch again');
  if (!versionBase) return console.log('Release-please has no proposal');

  const tags = listTags(image);
  const ledger = loadLedger(image, tags);
  const count = ledger.candidates.length;
  const candidate = reserveVersion(ledger, versionBase, channel, sha);
  const published = tags.has(`v${candidate.version}`);
  if (published && ledger.candidates.length !== count) {
    throw new Error(`Candidate tag v${candidate.version} exists without a reservation`);
  }
  if (published) verifyPublishedCandidate(image, candidate);
  if (!published && candidate.digest) return console.log(`Candidate v${candidate.version} was retired and will not be republished`);
  if (ledger.candidates.length !== count) saveLedger(image, ledger);
  setOutput('sha', sha);
  setOutput('version', candidate.version);
  setOutput('build', !published);
}

async function finalizeCandidate(indexPath) {
  const tags = listTags(image);
  const ledger = loadLedger(image, tags);
  const candidate = ledger.candidates.find(entry => entry.version === env.VERSION && entry.sha === env.SOURCE_SHA);
  if (!candidate) throw new Error('Candidate has no matching reservation');
  const tag = `v${candidate.version}`;

  if (!tags.has(tag)) {
    if (candidate.digest) throw new Error(`Retired candidate ${tag} cannot be republished`);
    if (!indexPath) throw new Error('Missing assembled candidate image index');
    verifyIndex(JSON.parse(readFileSync(indexPath)), candidate);
    oras(['manifest', 'push', `${image}:${tag}`, indexPath]);
  }
  const digest = verifyPublishedCandidate(image, candidate);
  if (!candidate.digest) {
    candidate.digest = digest;
    saveLedger(image, ledger);
  }
  if (env.MODE === 'rc' && await branchHead('main') === candidate.sha) {
    oras(['tag', `${image}@${digest}`, 'rc']);
  }
  appendFileSync(env.GITHUB_STEP_SUMMARY, `### ${tag}\n\nSource: \`${candidate.sha}\`\n\n\`docker pull ${image}:${tag}\`\n`);
}

async function main(command, ...args) {
  if (command === 'prepare') return prepareCandidate();
  if (command === 'finalize') return finalizeCandidate(...args);
  if (command === 'verify') return verifyIndex(JSON.parse(readFileSync(args[0])));
  if (command === 'stamp') {
    const [path, version] = args;
    if (!lstatSync(path).isFile()) throw new Error('Expected a regular mix.exs file');
    return writeFileSync(path, stampMixVersion(readFileSync(path, 'utf8'), version));
  }
  throw new Error(`Unknown candidate command: ${command}`);
}

if (require.main === module) {
  main(...process.argv.slice(2)).catch(error => { console.error(error.message); process.exitCode = 1; });
}

module.exports = {
  githubRequest, candidateVersionPattern, digestPattern,
  listTags, loadLedger, resolveTag, fetchManifest,
  proposeVersion, reserveVersion, stampMixVersion, validateLedger,
  verifyIndex, revisionAnnotation, versionAnnotation,
};
