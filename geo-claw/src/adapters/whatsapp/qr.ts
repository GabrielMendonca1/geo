import fs from 'node:fs/promises';
import path from 'node:path';
import QRCode from 'qrcode';
import { paths } from '../../config.js';

const PNG_PATH = path.join(paths.signalsDir, 'qr.png');
const TXT_PATH = path.join(paths.signalsDir, 'qr.txt');

async function ensureSignalsDir(): Promise<void> {
  await fs.mkdir(paths.signalsDir, { recursive: true });
}

async function atomicWrite(target: string, data: Buffer | string): Promise<void> {
  const tmp = `${target}.tmp-${process.pid}-${Date.now()}`;
  if (typeof data === 'string') {
    await fs.writeFile(tmp, data, 'utf8');
  } else {
    await fs.writeFile(tmp, data);
  }
  await fs.rename(tmp, target);
}

export async function writeQrFile(qrString: string): Promise<void> {
  await ensureSignalsDir();
  const png = await QRCode.toBuffer(qrString, {
    type: 'png',
    width: 512,
    margin: 2,
    errorCorrectionLevel: 'M',
  });
  const ascii = await QRCode.toString(qrString, {
    type: 'terminal',
    small: true,
  });
  await atomicWrite(PNG_PATH, png);
  await atomicWrite(TXT_PATH, ascii);
}

export async function clearQrFile(): Promise<void> {
  await Promise.allSettled([
    fs.rm(PNG_PATH, { force: true }),
    fs.rm(TXT_PATH, { force: true }),
  ]);
}
