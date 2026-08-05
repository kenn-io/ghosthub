import { describe, expect, it, vi } from 'vitest';
import { copyInstallCommand } from './install';

describe('copyInstallCommand', () => {
  it('copies the exact command and reports success', async () => {
    const writeText = vi.fn(async () => undefined);
    const result = await copyInstallCommand(
      writeText,
      'brew install kenn-io/tap/ghosthub',
    );

    expect(writeText).toHaveBeenCalledWith(
      'brew install kenn-io/tap/ghosthub',
    );
    expect(result).toBe('copied');
  });

  it('reports failure when the browser rejects clipboard access', async () => {
    const writeText = vi.fn(async () => Promise.reject(new Error('denied')));

    await expect(
      copyInstallCommand(writeText, 'brew install kenn-io/tap/ghosthub'),
    ).resolves.toBe('failed');
  });
});
