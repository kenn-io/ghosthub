export type CopyInstallResult = 'copied' | 'failed';

export async function copyInstallCommand(
  writeText: (value: string) => Promise<void>,
  command: string,
): Promise<CopyInstallResult> {
  try {
    await writeText(command);
    return 'copied';
  } catch {
    return 'failed';
  }
}
