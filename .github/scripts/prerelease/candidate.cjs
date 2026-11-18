const { appendFileSync, lstatSync, readFileSync, writeFileSync } = require('node:fs');
const { join } = require('node:path');
const { proposeVersion, reserveVersion, stampMixVersion, stableVersionPattern } = require('./versions.cjs');
const { oras, listTags, loadLedger, saveLedger, verifyIndex, verifyPublishedCandidate } = require('./registry.cjs');

const env = process.env;
const configPath = join(__dirname, '../../../release-please-config.json');
const image = `ghcr.io/${env.GITHUB_REPOSITORY?.toLowerCase()}`;

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

module.exports = { githubRequest };
