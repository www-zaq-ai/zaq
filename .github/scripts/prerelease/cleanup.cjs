const { appendFileSync } = require('node:fs');
const {
  githubRequest, candidateVersionPattern, digestPattern,
  listTags, loadLedger, resolveTag, fetchManifest,
} = require('./candidate.cjs');

const retentionMs = 7 * 24 * 60 * 60 * 1000;
const minimumPerChannel = 3;

function versionTags(version) {
  return version.metadata?.container?.tags ?? [];
}

function expiredCandidates(versions, now) {
  return ['rc', 'beta'].flatMap(channel => {
    const candidates = versions.filter(row => versionTags(row).some(tag =>
      tag.startsWith('v') && candidateVersionPattern.exec(tag.slice(1))?.[2] === channel));
    if (candidates.some(row => !Number.isFinite(Date.parse(row.created_at)))) {
      throw new Error(`Missing publication date for a ${channel} candidate`);
    }
    return candidates
      .sort((a, b) => Date.parse(b.created_at) - Date.parse(a.created_at) || b.id - a.id)
      .slice(minimumPerChannel)
      .filter(row => versionTags(row).length === 1 && digestPattern.test(row.name) &&
        now - Date.parse(row.created_at) > retentionMs);
  });
}

function protectReferencedVersions(expired, remoteTags, readManifest) {
  const deletableTags = new Set(expired.map(row => versionTags(row)[0]));
  const pending = [...remoteTags].filter(([tag]) => !deletableTags.has(tag)).map(([, digest]) => digest);
  const visited = new Set();

  while (pending.length) {
    const digest = pending.pop();
    if (visited.has(digest)) continue;
    visited.add(digest);
    const manifest = readManifest(digest);
    for (const child of [...(manifest.manifests ?? []), manifest.subject].filter(Boolean)) {
      if (!digestPattern.test(child.digest)) throw new Error('Invalid digest in retained registry manifest');
      pending.push(child.digest);
    }
  }
  return expired.filter(row => remoteTags.get(versionTags(row)[0]) === row.name && !visited.has(row.name));
}

async function listActiveVersions(path) {
  const versions = [];
  for (let page = 1; ; page++) {
    const response = await githubRequest(`${path}?state=active&per_page=100&page=${page}`);
    versions.push(...response.body);
    if (!response.link?.includes('rel="next"')) return versions;
  }
}

async function cleanup() {
  const env = process.env;
  const apply = env.DELETE_EXPIRED === 'true';
  const report = [`### Candidate cleanup (${apply ? 'delete' : 'dry run'})`];
  function writeReport() {
    if (report.length === 1) report.push('No eligible candidates.');
    appendFileSync(env.GITHUB_STEP_SUMMARY, `\n${report.join('\n')}\n`);
  }

  const [owner, repo] = env.GITHUB_REPOSITORY.toLowerCase().split('/');
  const image = `ghcr.io/${owner}/${repo}`;
  const tags = listTags(image);
  const ledger = loadLedger(image, tags);
  if (!ledger.candidates.some(candidate => candidate.digest)) return writeReport();

  const account = (await githubRequest(`/users/${encodeURIComponent(owner)}`)).body;
  const accountPath = account.type === 'Organization' ? 'orgs' : 'users';
  const versionsPath = `/${accountPath}/${encodeURIComponent(owner)}/packages/container/${encodeURIComponent(repo)}/versions`;
  const versions = (await listActiveVersions(versionsPath))
    .filter(row => versionTags(row).some(tag => tags.has(tag)));
  const recorded = new Map(ledger.candidates.map(entry => [`v${entry.version}`, entry.digest]));
  const expired = expiredCandidates(versions, Date.now())
    .filter(row => recorded.get(versionTags(row)[0]) === row.name);
  if (expired.length === 0) return writeReport();

  const remoteTags = new Map([...tags].map(tag => [tag, resolveTag(image, tag)]));
  const deletable = protectReferencedVersions(expired, remoteTags, digest => fetchManifest(image, digest));
  for (const version of deletable) {
    const [tag] = versionTags(version);
    if (apply) {
      const path = `${versionsPath}/${version.id}`;
      const current = (await githubRequest(path, { allowMissing: true }))?.body;
      if (!current || current.name !== version.name ||
          versionTags(current).length !== 1 || versionTags(current)[0] !== tag ||
          resolveTag(image, tag) !== version.name) continue;
      await githubRequest(path, { method: 'DELETE' });
    }
    report.push(`- ${apply ? 'Deleted' : 'Would delete'} \`${tag}\` (${version.name})`);
  }
  writeReport();
}

if (require.main === module) cleanup().catch(error => { console.error(error.message); process.exitCode = 1; });

module.exports = { expiredCandidates, protectReferencedVersions };
