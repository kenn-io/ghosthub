export interface ReleaseAsset {
  name: string;
  browser_download_url: string;
}

export interface Release {
  tag_name: string;
  assets: ReleaseAsset[];
}

export interface Download {
  url: string;
  version: string;
}

const DMG_PATTERN = /^Ghosthub_.+_macos_(arm64|aarch64)\.dmg$/;

export function pickDownload(release: Release): Download | null {
  const asset = release.assets.find((a) => DMG_PATTERN.test(a.name));
  if (asset === undefined) return null;
  return { url: asset.browser_download_url, version: release.tag_name };
}

export function formatCount(count: number): string {
  if (count < 1000) return String(count);
  const thousands = count / 1000;
  const rounded = thousands >= 10 ? Math.round(thousands) : Math.round(thousands * 10) / 10;
  return `${rounded}k`;
}

interface CacheEntry<T> {
  at: number;
  value: T;
}

export function readCache<T>(
  storage: Pick<Storage, 'getItem'>,
  key: string,
  maxAgeMs: number,
  now: number,
): T | null {
  const raw = storage.getItem(key);
  if (raw === null) return null;
  try {
    const entry = JSON.parse(raw) as CacheEntry<T>;
    if (now - entry.at > maxAgeMs) return null;
    return entry.value;
  } catch {
    return null;
  }
}

export function writeCache<T>(
  storage: Pick<Storage, 'setItem'>,
  key: string,
  value: T,
  now: number,
): void {
  storage.setItem(key, JSON.stringify({ at: now, value } satisfies CacheEntry<T>));
}
