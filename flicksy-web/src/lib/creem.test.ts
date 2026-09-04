import { describe, expect, it, vi } from 'vitest';
import { createCheckout, retrieveCompletedCheckout, verifyRedirectSignature } from './creem';
import type { CreemRuntimeConfig } from './environment';

const config: CreemRuntimeConfig = {
  environment: 'test',
  siteURL: 'https://preview.flicksy.me',
  directDownloadURL: 'https://example.com/Flicksy-Test.dmg',
  apiURL: 'https://test-api.creem.io',
  apiKey: 'creem_test_unit_test_key',
  productID: 'prod_test123',
};

describe('Creem checkout', () => {
  it('creates a hosted checkout with environment metadata', async () => {
    const fetcher = vi.fn(async () => new Response(JSON.stringify({
      checkout_url: 'https://creem.io/test/checkout/ch_123',
    }), { status: 200 })) as unknown as typeof fetch;

    await expect(createCheckout(config, 'app', fetcher)).resolves.toBe(
      'https://creem.io/test/checkout/ch_123',
    );
    const [, init] = vi.mocked(fetcher).mock.calls[0];
    expect(JSON.parse(String(init?.body))).toMatchObject({
      product_id: 'prod_test123',
      success_url: 'https://preview.flicksy.me/purchase/success',
      metadata: { source: 'app', environment: 'test' },
    });
  });

  it('accepts Creem checkout hosts used in test and live', async () => {
    for (const checkoutURL of [
      'https://creem.io/test/checkout/ch_123',
      'https://www.creem.io/test/checkout/ch_123',
      'https://checkout.creem.io/ch_123',
    ]) {
      const fetcher = vi.fn(async () => new Response(JSON.stringify({
        checkout_url: checkoutURL,
      }), { status: 200 })) as unknown as typeof fetch;
      await expect(createCheckout(config, 'web', fetcher)).resolves.toBe(checkoutURL);
    }
  });

  it('reads camelCase checkoutUrl from Creem', async () => {
    const fetcher = vi.fn(async () => new Response(JSON.stringify({
      checkoutUrl: 'https://creem.io/test/checkout/ch_123',
    }), { status: 200 })) as unknown as typeof fetch;

    await expect(createCheckout(config, 'web', fetcher)).resolves.toBe(
      'https://creem.io/test/checkout/ch_123',
    );
  });

  it('rejects a checkout URL off the Creem domain', async () => {
    const fetcher = vi.fn(async () => new Response(JSON.stringify({
      checkout_url: 'https://example.com/checkout/ch_123',
    }), { status: 200 })) as unknown as typeof fetch;

    await expect(createCheckout(config, 'web', fetcher)).rejects.toThrow(
      'Creem returned an invalid checkout URL.',
    );
  });

  it('returns only a completed matching license', async () => {
    const fetcher = vi.fn(async () => new Response(JSON.stringify({
      id: 'ch_123',
      mode: 'test',
      status: 'completed',
      product: { id: 'prod_test123' },
      metadata: { environment: 'test', source: 'web' },
      license_keys: [{
        key: 'ABCD-EFGH-IJKL',
        mode: 'test',
        product_id: 'prod_test123',
        status: 'active',
      }],
    }), { status: 200 })) as unknown as typeof fetch;

    await expect(retrieveCompletedCheckout(config, 'ch_123', fetcher)).resolves.toEqual({
      checkoutID: 'ch_123',
      licenseKey: 'ABCD-EFGH-IJKL',
    });
  });

  it('rejects a license returned from the opposite mode', async () => {
    const fetcher = vi.fn(async () => new Response(JSON.stringify({
      id: 'ch_123', mode: 'prod', status: 'completed', product_id: 'prod_test123',
      metadata: { environment: 'test', source: 'web' },
    }), { status: 200 })) as unknown as typeof fetch;

    await expect(retrieveCompletedCheckout(config, 'ch_123', fetcher)).rejects.toThrow(
      'does not match this Flicksy environment',
    );
  });

  it('verifies Creem signed redirect parameters in their received order', async () => {
    const unsigned = 'checkout_id=ch_123|order_id=ord_123|salt=creem_test_unit_test_key';
    const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(unsigned));
    const signature = Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, '0')).join('');

    await expect(verifyRedirectSignature(
      `checkout_id=ch_123&order_id=ord_123&signature=${signature}`,
      config.apiKey,
    )).resolves.toBe(true);
    await expect(verifyRedirectSignature(
      `checkout_id=ch_999&order_id=ord_123&signature=${signature}`,
      config.apiKey,
    )).resolves.toBe(false);
  });
});
