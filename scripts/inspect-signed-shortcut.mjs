// Read our generated Apple-signed AEA file without importing or running the shortcut.
// aea verifies the signature using the signing certificate embedded in the archive;
// this is an integrity check on our build output, not independent certificate-chain trust.
import { X509Certificate } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

export function inspectSignedShortcut(path) {
  const bytes = readFileSync(path);
  if (bytes.subarray(0, 4).toString() !== 'AEA1' || bytes.readUInt32LE(4) !== 0) throw new Error('unexpected-shortcut-archive');
  const dir = mkdtempSync(join(tmpdir(), 'nigeyo-shortcut-inspect-'));
  try {
    const metadataPath = join(dir, 'metadata.plist');
    writeFileSync(metadataPath, bytes.subarray(12, 12 + bytes.readUInt32LE(8)));
    const leafBase64 = execFileSync('plutil', ['-extract', 'SigningCertificateChain.0', 'raw', '-o', '-', metadataPath], { encoding: 'utf8' }).trim();
    const cert = new X509Certificate(Buffer.from(leafBase64, 'base64'));
    if (cert.publicKey.asymmetricKeyType !== 'ec' || cert.publicKey.asymmetricKeyDetails.namedCurve !== 'prime256v1') throw new Error('unexpected-signing-key');
    const publicKey = cert.publicKey.export({ format: 'der', type: 'spki' }).subarray(-65);
    const archive = join(dir, 'workflow.aar');
    execFileSync('aea', ['decrypt', '-i', resolve(path), '-o', archive, '-sign-pub-value', `hex:${publicKey.toString('hex')}`]);
    execFileSync('aa', ['extract', '-i', archive, '-d', dir]);
    return JSON.parse(execFileSync('plutil', ['-convert', 'json', '-o', '-', join(dir, 'Shortcut.wflow')], {
      encoding: 'utf8', maxBuffer: 8 * 1024 * 1024,
    }));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}
