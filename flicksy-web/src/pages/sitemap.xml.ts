import type { APIRoute } from 'astro';
import { docPath, getDocs } from '../lib/docs';
import { canonicalURL } from '../lib/seo';

export const prerender = true;

export const GET: APIRoute = async () => {
  const paths = ['/', '/docs', '/privacy', '/license', '/refunds', ...(await getDocs()).map(docPath)];
  const escapeXML = (value: string) => value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  const urls = paths.map((path) => `<url><loc>${escapeXML(canonicalURL(path))}</loc></url>`).join('\n');
  return new Response(`<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls}\n</urlset>`, {
    headers: { 'Content-Type': 'application/xml; charset=utf-8' },
  });
};
