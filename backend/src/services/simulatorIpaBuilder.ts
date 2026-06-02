import { execFile as execFileCb } from 'child_process';
import { promisify } from 'util';
import fs from 'fs';
import os from 'os';
import path from 'path';

const execFile = promisify(execFileCb);
const EXEC_MAX_BUFFER = 10 * 1024 * 1024;
const activeBuilds = new Map<string, Promise<string>>();

function derivedOutputPath(sourceIpaPath: string): string {
  const dir = path.dirname(sourceIpaPath);
  const ext = path.extname(sourceIpaPath);
  const base = path.basename(sourceIpaPath, ext);
  return path.join(dir, `${base}.simulator${ext || '.ipa'}`);
}

export function simulatorIpaPathFor(sourceIpaPath: string): string {
  return derivedOutputPath(sourceIpaPath);
}

export async function ensureSimulatorIpa(sourceIpaPath: string): Promise<string> {
  const resolvedSource = path.resolve(sourceIpaPath);
  const outputPath = simulatorIpaPathFor(resolvedSource);
  const resolvedOutput = path.resolve(outputPath);
  const existingBuild = activeBuilds.get(resolvedOutput);
  if (existingBuild) return existingBuild;

  const build = buildIfNeeded(resolvedSource, outputPath);
  activeBuilds.set(resolvedOutput, build);
  try {
    return await build;
  } finally {
    activeBuilds.delete(resolvedOutput);
  }
}

async function buildIfNeeded(sourceIpaPath: string, outputPath: string): Promise<string> {
  const sourceStat = await fs.promises.stat(sourceIpaPath);
  try {
    const outputStat = await fs.promises.stat(outputPath);
    if (outputStat.mtimeMs >= sourceStat.mtimeMs) return outputPath;
  } catch {
    // Missing derived IPA means the requested simulator build should be created.
  }

  await buildSimulatorIpa(sourceIpaPath, outputPath);
  return outputPath;
}

async function buildSimulatorIpa(
  sourceIpaPath: string,
  outputPath: string,
): Promise<void> {
  const tmpDir = await fs.promises.mkdtemp(
    path.join(os.tmpdir(), 'asspp-simulator-'),
  );
  const outputTmpPath = path.join(
    path.dirname(outputPath),
    `.${path.basename(outputPath)}.${process.pid}.${Date.now()}.tmp`,
  );

  try {
    await run('unzip', ['-qq', sourceIpaPath], tmpDir);

    const appDir = await singlePayloadAppDirectory(tmpDir);
    await prepareAppBundle(appDir);

    const machOFiles = await findMachOFiles(appDir);
    if (machOFiles.length === 0) {
      throw new Error('No Mach-O files found in IPA');
    }

    for (const filePath of machOFiles) {
      await patchMachOFile(filePath);
    }

    await run('codesign', ['-s', '-', '--force', '--deep', appDir]);
    await run('codesign', ['--verify', '--deep', appDir]);

    const topLevelEntries = await fs.promises.readdir(tmpDir);
    await fs.promises.rm(outputTmpPath, { force: true });
    await run('zip', ['-qry', outputTmpPath, '--', ...topLevelEntries], tmpDir);
    await fs.promises.rename(outputTmpPath, outputPath);
  } finally {
    await fs.promises.rm(tmpDir, { recursive: true, force: true });
    await fs.promises.rm(outputTmpPath, { force: true });
  }
}

async function singlePayloadAppDirectory(tmpDir: string): Promise<string> {
  const payloadDir = path.join(tmpDir, 'Payload');
  const entries = await fs.promises.readdir(payloadDir, { withFileTypes: true });
  const apps = entries
    .filter((entry) => entry.isDirectory() && entry.name.endsWith('.app'))
    .map((entry) => path.join(payloadDir, entry.name));

  if (apps.length !== 1) {
    throw new Error('IPA must contain exactly one Payload/*.app bundle');
  }
  return apps[0];
}

async function prepareAppBundle(appDir: string): Promise<void> {
  const removableEntries = [
    'embedded.mobileprovision',
    '_CodeSignature',
    'PlugIns',
    'SC_Info',
  ];

  for (const entry of removableEntries) {
    await fs.promises.rm(path.join(appDir, entry), {
      recursive: true,
      force: true,
    });
  }
}

async function findMachOFiles(rootDir: string): Promise<string[]> {
  const files: string[] = [];
  await walkFiles(rootDir, async (filePath) => {
    const { stdout } = await run('file', [filePath], rootDir);
    if (stdout.includes('Mach-O')) {
      files.push(filePath);
    }
  });
  return files;
}

async function walkFiles(
  dir: string,
  visit: (filePath: string) => Promise<void>,
): Promise<void> {
  const entries = await fs.promises.readdir(dir, { withFileTypes: true });
  for (const entry of entries) {
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      await walkFiles(fullPath, visit);
      continue;
    }
    if (entry.isFile()) {
      await visit(fullPath);
    }
  }
}

async function patchMachOFile(filePath: string): Promise<void> {
  await run('vtool', [
    '-arch',
    'arm64',
    '-set-build-version',
    'iossim',
    '16.0',
    '16.0',
    '-replace',
    '-output',
    filePath,
    filePath,
  ]);
  await run('codesign', ['--remove', filePath]);
  await run('codesign', ['-s', '-', '--force', '--deep', filePath]);
  await fs.promises.chmod(filePath, 0o777);
}

async function run(
  command: string,
  args: string[],
  cwd?: string,
): Promise<{ stdout: string; stderr: string }> {
  try {
    const { stdout, stderr } = await execFile(command, args, {
      cwd,
      maxBuffer: EXEC_MAX_BUFFER,
    });
    return { stdout: stdout.toString(), stderr: stderr.toString() };
  } catch (error) {
    if (error instanceof Error) {
      throw new Error(`${command} failed: ${error.message}`);
    }
    throw error;
  }
}
