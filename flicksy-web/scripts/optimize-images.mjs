import sharp from 'sharp';
import { mkdir, stat } from 'node:fs/promises';

const publicDir = new URL('../public/', import.meta.url);
await mkdir(new URL('optimized/', publicDir), { recursive: true });
const screenshots = ['app-browser-dinos.jpeg', 'app-browser-audio.png', 'app-preview-crop.jpeg', 'app-compare.jpeg'];
for (const file of screenshots) {
  for (const width of [640, 1200, 1784]) {
    const destination = new URL(`optimized/${file.split('.')[0]}-${width}.webp`, publicDir);
    await sharp(new URL(file, publicDir).pathname).resize({ width, withoutEnlargement: true }).webp({ quality: 82 }).toFile(destination.pathname);
    console.log(`${destination.pathname.split('/').pop()}: ${Math.round((await stat(destination)).size / 1024)} KB`);
  }
}
await sharp(new URL('app-browser-dinos.jpeg', publicDir).pathname)
  .resize({ width: 1200 }).jpeg({ quality: 85 }).toFile(new URL('social-preview.jpg', publicDir).pathname);
