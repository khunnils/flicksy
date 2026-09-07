import type { APIRoute } from 'astro';
import { env } from 'cloudflare:workers';
import { readPublicConfig } from '../lib/environment';

export const prerender = false;

export const GET: APIRoute = async ({ redirect }) => {
  const appStoreURL = readPublicConfig(env).appStoreURL;
  if (appStoreURL) return redirect(appStoreURL, 303);
  return new Response('Flicksy is not available on the App Store yet. Please check back soon.', {
    status: 503,
    headers: { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' },
  });
};
