import { createRequire } from 'node:module';
import pino from 'pino';
import { paths, ensureDirs } from './config.js';

ensureDirs();

const isDev = process.env.GEO_CLAW_DEV === '1';

const targets: pino.TransportTargetOptions[] = [
  {
    target: 'pino/file',
    level: 'debug',
    options: { destination: paths.logFile, mkdir: true },
  },
];

if (isDev) {
  const require = createRequire(import.meta.url);
  try {
    require.resolve('pino-pretty');
    targets.push({
      target: 'pino-pretty',
      level: 'debug',
      options: { destination: 1, colorize: true, translateTime: 'SYS:HH:MM:ss.l' },
    });
  } catch {
    process.stderr.write('geo-claw: GEO_CLAW_DEV=1 set but pino-pretty not installed; logging to file only.\n');
  }
}

export const log = pino(
  { level: process.env.GEO_CLAW_LOG_LEVEL ?? 'info' },
  pino.transport({ targets }),
);
