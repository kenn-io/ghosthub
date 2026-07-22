import { GITHUB_REPO } from '../config';
import {
  formatCount,
  pickDownload,
  readCache,
  writeCache,
  type Release,
} from '../lib/github';

const API = `https://api.github.com/repos/${GITHUB_REPO}`;
const HOUR_MS = 60 * 60 * 1000;

async function cachedJson<T>(key: string, url: string): Promise<T | null> {
  const now = Date.now();
  const cached = readCache<T>(localStorage, key, HOUR_MS, now);
  if (cached !== null) return cached;
  const res = await fetch(url, {
    headers: { Accept: 'application/vnd.github+json' },
  });
  if (!res.ok) return null;
  const value = (await res.json()) as T;
  writeCache(localStorage, key, value, now);
  return value;
}

function setFact(name: string, text: string): void {
  const fact = document.querySelector(`[data-fact="${name}"]`);
  if (!(fact instanceof HTMLElement)) return;
  const label = fact.querySelector('[data-fact-text]');
  if (label === null) return;
  label.textContent = text;
  fact.hidden = false;
  const row = document.querySelector('[data-facts]');
  if (row instanceof HTMLElement) row.hidden = false;
}

async function renderRepoFacts(): Promise<void> {
  const repo = await cachedJson<{
    stargazers_count: number;
    forks_count: number;
  }>('ghosthub:repo:v2', API);
  if (repo === null) return;
  setFact('stars', formatCount(repo.stargazers_count));
  setFact('forks', formatCount(repo.forks_count));
}

async function renderDownload(): Promise<void> {
  const release = await cachedJson<Release>(
    'ghosthub:release',
    `${API}/releases/latest`,
  );
  if (release === null) return;
  setFact('version', release.tag_name);
  const download = pickDownload(release);
  if (download === null) return;
  for (const anchor of document.querySelectorAll('[data-download]')) {
    if (anchor instanceof HTMLAnchorElement) anchor.href = download.url;
  }
  const version = document.querySelector('[data-version]');
  if (version !== null) version.textContent = `${download.version} · `;
}

function ignoreNetworkFailure(err: unknown): void {
  console.warn('github api unavailable, using static fallbacks', err);
}

renderRepoFacts().catch(ignoreNetworkFailure);
renderDownload().catch(ignoreNetworkFailure);
