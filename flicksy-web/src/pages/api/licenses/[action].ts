import type { APIRoute } from 'astro';
import { env } from 'cloudflare:workers';
import { handleLicenseRequest } from '../../../lib/creem-licenses';

export const prerender = false;

export const POST: APIRoute = async ({ params, request }) => {
  return handleLicenseRequest(params.action ?? '', request, {
    FLICKSY_ENVIRONMENT: env.FLICKSY_ENVIRONMENT,
    FLICKSY_SITE_URL: env.FLICKSY_SITE_URL,
    FLICKSY_DIRECT_DOWNLOAD_URL: env.FLICKSY_DIRECT_DOWNLOAD_URL,
    FLICKSY_APP_STORE_URL: env.FLICKSY_APP_STORE_URL,
    CREEM_API_KEY: env.CREEM_API_KEY,
    CREEM_PRODUCT_ID: env.CREEM_PRODUCT_ID,
  });
};
