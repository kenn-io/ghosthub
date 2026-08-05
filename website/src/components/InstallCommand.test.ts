import { experimental_AstroContainer as AstroContainer } from 'astro/container';
import { beforeAll, describe, expect, it } from 'vitest';
import InstallCommand from './InstallCommand.astro';

describe('InstallCommand', () => {
  let container: AstroContainer;

  beforeAll(async () => {
    container = await AstroContainer.create();
  });

  it('renders a supplied secondary action beside the DMG fallback', async () => {
    const html = await container.renderToString(InstallCommand, {
      slots: {
        secondary: '<a href="/guide/">Learn More</a>',
      },
    });

    expect(html).toContain('href="/guide/"');
    expect(html.indexOf('download the DMG')).toBeLessThan(
      html.indexOf('Learn More'),
    );
  });

  it('omits the secondary action when no slot is supplied', async () => {
    const html = await container.renderToString(InstallCommand);

    expect(html).not.toContain('href="/guide/"');
  });
});
