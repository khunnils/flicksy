import type { APIRoute } from 'astro';
import { env } from 'cloudflare:workers';
import { configurationReadiness } from '../../lib/environment';

export const prerender = false;

export const GET: APIRoute = async () => {
  const readiness = configurationReadiness(env);
  const environment = env.FLICKSY_ENVIRONMENT === 'production' ? 'production' : 'test';
  const ready = readiness.site && readiness.commerce;
  return new Response(JSON.stringify({ ok: ready, environment, readiness }), {
    status: ready ? 200 : 503,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
    },
  });
};
