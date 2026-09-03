import type { APIRoute } from 'astro';
import { env } from 'cloudflare:workers';
import { handleLicenseRequest } from '../../../lib/creem-licenses';

export const prerender = false;

export const POST: APIRoute = async ({ params, request }) => {
  return handleLicenseRequest(params.action ?? '', request, {
    CREEM_API_KEY: env.CREEM_API_KEY,
    CREEM_PRODUCT_ID: env.CREEM_PRODUCT_ID,
  });
};
