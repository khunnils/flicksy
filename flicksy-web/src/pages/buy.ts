import type { APIRoute } from 'astro';
import { env } from 'cloudflare:workers';
import { createCheckout, type CheckoutSource } from '../lib/creem';
import { readCreemConfig } from '../lib/environment';

export const prerender = false;

export const GET: APIRoute = async ({ request, redirect }) => {
  const sourceValue = new URL(request.url).searchParams.get('source');
  const source: CheckoutSource = sourceValue === 'app' ? 'app' : 'web';
  try {
    const checkoutURL = await createCheckout(readCreemConfig(env), source);
    return redirect(checkoutURL, 303);
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Checkout is unavailable.';
    return new Response(message, {
      status: 503,
      headers: { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' },
    });
  }
};
