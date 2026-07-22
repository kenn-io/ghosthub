import { describe, expect, it } from 'vitest';
import { formatCount, pickDownload, readCache, writeCache, type Release } from './github';

const release: Release = {
  tag_name: 'v0.1.0',
  assets: [
    { name: 'Ghosthub_0.1.0_macos_arm64.dmg.sha256', browser_download_url: 'https://x/sha' },
    { name: 'Ghosthub_0.1.0_macos_arm64.dmg', browser_download_url: 'https://x/dmg' },
  ],
};

describe('pickDownload', () => {
  it('picks the arm64 dmg, not the sha256', () => {
    expect(pickDownload(release)).toEqual({ url: 'https://x/dmg', version: 'v0.1.0' });
  });

  it('accepts aarch64 naming', () => {
    const r: Release = {
      tag_name: 'v0.2.0',
      assets: [{ name: 'Ghosthub_0.2.0_macos_aarch64.dmg', browser_download_url: 'https://x/a' }],
    };
    expect(pickDownload(r)?.url).toBe('https://x/a');
  });

  it('returns null when no dmg asset exists', () => {
    expect(pickDownload({ tag_name: 'v1', assets: [] })).toBeNull();
  });
});

describe('formatCount', () => {
  it.each([
    [0, '0'],
    [842, '842'],
    [1234, '1.2k'],
    [9950, '10k'],
    [15600, '16k'],
  ])('formats %i as %s', (input, expected) => {
    expect(formatCount(input)).toBe(expected);
  });
});

function memoryStorage(): Pick<Storage, 'getItem' | 'setItem'> & { data: Map<string, string> } {
  const data = new Map<string, string>();
  return {
    data,
    getItem: (k) => data.get(k) ?? null,
    setItem: (k, v) => void data.set(k, v),
  };
}

describe('cache', () => {
  it('round-trips a fresh value', () => {
    const s = memoryStorage();
    writeCache(s, 'k', { n: 1 }, 1000);
    expect(readCache(s, 'k', 60_000, 2000)).toEqual({ n: 1 });
  });

  it('returns null for a stale value', () => {
    const s = memoryStorage();
    writeCache(s, 'k', { n: 1 }, 1000);
    expect(readCache(s, 'k', 60_000, 70_000)).toBeNull();
  });

  it('returns null for a missing key and for corrupt JSON', () => {
    const s = memoryStorage();
    expect(readCache(s, 'missing', 60_000, 0)).toBeNull();
    s.data.set('bad', '{not json');
    expect(readCache(s, 'bad', 60_000, 0)).toBeNull();
  });
});
