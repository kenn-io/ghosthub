import { experimental_AstroContainer as AstroContainer } from 'astro/container';
import { beforeAll, describe, expect, it } from 'vitest';
import Hero from './Hero.astro';
import InstallCommand from './InstallCommand.astro';

describe('InstallCommand', () => {
  let container: AstroContainer;

  beforeAll(async () => {
    container = await AstroContainer.create();
  });

  it('renders secondary actions together below the primary command', async () => {
    const html = await container.renderToString(InstallCommand, {
      slots: {
        secondary: '<a href="/overview/">Learn More</a>',
      },
    });

    expect(html).toContain('href="/overview/"');
    expect(html.indexOf('brew install kenn-io/tap/ghosthub')).toBeLessThan(
      html.indexOf('Download DMG'),
    );
    expect(html.indexOf('Download DMG')).toBeLessThan(
      html.indexOf('Learn More'),
    );
  });

  it('omits the secondary action when no slot is supplied', async () => {
    const html = await container.renderToString(InstallCommand);

    expect(html).not.toContain('href="/overview/"');
  });

  it('keeps Homebrew primary while exposing the Overview', async () => {
    const html = await container.renderToString(Hero);
    const commandIndex = html.indexOf('brew install kenn-io/tap/ghosthub');
    const overviewIndex = html.indexOf('href="/overview/"');

    expect(commandIndex).toBeGreaterThan(-1);
    expect(overviewIndex).toBeGreaterThan(commandIndex);
    expect(html.slice(overviewIndex)).toContain('Learn More');
  });
});
