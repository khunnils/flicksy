import type { APIRoute } from 'astro';
import { canonicalURL } from '../lib/seo';

export const prerender = true;

// Allow page crawling so crawlers can read noindex on preview and purchase pages.
export const GET: APIRoute = () => new Response(
  `User-agent: *\nAllow: /\nDisallow: /api/\nDisallow: /buy\n${import.meta.env.FLICKSY_DEPLOY_ENV === 'test' ? '' : `\nSitemap: ${canonicalURL('/sitemap.xml')}\n`}`,
  { headers: { 'Content-Type': 'text/plain; charset=utf-8' } },
);
