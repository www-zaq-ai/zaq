const stableVersionPattern = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;
const candidateVersionPattern = /^((?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*))-(rc|beta)\.([1-9]\d*)$/;
const shaPattern = /^[a-f0-9]{40}$/;
const digestPattern = /^sha256:[a-f0-9]{64}$/;

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

module.exports = { proposeVersion, reserveVersion, stampMixVersion, validateLedger, candidateVersionPattern, digestPattern, stableVersionPattern };
