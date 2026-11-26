import fs from 'fs';
import path from 'path';

const root = process.cwd();
const distDir = path.resolve(root, 'dist');
fs.mkdirSync(distDir, { recursive: true });

const envPayload = {
  VITE_SUPABASE_URL: (process.env.VITE_SUPABASE_URL || '').trim(),
  VITE_SUPABASE_ANON_KEY: (process.env.VITE_SUPABASE_ANON_KEY || '').trim(),
  VITE_OFFLINE_PIN_HASH: (
    process.env.VITE_OFFLINE_PIN_HASH ||
    'a037a7dfaf26abe1265bd5d51447be3bb1fdaef7c4c7a14bcf0d819818fb80b0'
  ).trim()
};

const htmlSrc = fs.readFileSync(path.resolve(root, 'index.html'), 'utf8');
const injected = htmlSrc.replace(
  '/*__ENV_INJECT__*/',
  `window.__TAFAQ_ENV__ = ${JSON.stringify(envPayload)};`
);

fs.writeFileSync(path.resolve(distDir, 'index.html'), injected, 'utf8');

for (const file of ['manifest.webmanifest', 'sw.js']) {
  const srcPath = path.resolve(root, file);
  if (fs.existsSync(srcPath)) {
    fs.copyFileSync(srcPath, path.resolve(distDir, file));
  }
}

console.log('Build v2.5.0 completed successfully -> dist/');
