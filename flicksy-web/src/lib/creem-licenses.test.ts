import { describe, expect, it, vi } from 'vitest';
import { handleLicenseRequest } from './creem-licenses';
import type { FlicksyBindings } from './environment';

const bindings: FlicksyBindings = {
  FLICKSY_ENVIRONMENT: 'test',
  FLICKSY_SITE_URL: 'https://preview.flicksy.me',
  FLICKSY_DIRECT_DOWNLOAD_URL: 'https://example.com/Flicksy-Test.dmg',
  CREEM_API_KEY: 'creem_test_unit_test_key',
  CREEM_PRODUCT_ID: 'prod_test123',
};

function activateRequest() {
  return new Request('https://preview.flicksy.me/api/licenses/activate', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ key: 'ABCD', instance_name: 'install-123' }),
  });
}

describe('license proxy', () => {
  it('accepts a matching test product and mode', async () => {
    const fetcher = vi.fn(async () => new Response(JSON.stringify({
      mode: 'test',
      status: 'active',
      product_id: 'prod_test123',
      instance: { id: 'inst_123', name: 'install-123' },
      activation: 1,
      activation_limit: 3,
    }), { status: 200 })) as unknown as typeof fetch;

    const response = await handleLicenseRequest('activate', activateRequest(), bindings, fetcher);
    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({
      ok: true,
      instance_id: 'inst_123',
      activation_limit: 3,
    });
  });

  it('rejects a key belonging to another product', async () => {
    const fetcher = vi.fn(async () => new Response(JSON.stringify({
      mode: 'test',
      status: 'active',
      product_id: 'prod_other',
      instance: { id: 'inst_123', name: 'install-123' },
    }), { status: 200 })) as unknown as typeof fetch;

    const response = await handleLicenseRequest('activate', activateRequest(), bindings, fetcher);
    expect(response.status).toBe(404);
    await expect(response.json()).resolves.toMatchObject({ ok: false, error_code: 'invalid' });
  });

  it('rejects a production response returned to the test Worker', async () => {
    const fetcher = vi.fn(async () => new Response(JSON.stringify({
      mode: 'prod',
      status: 'active',
      product_id: 'prod_test123',
      instance: { id: 'inst_123', name: 'install-123' },
    }), { status: 200 })) as unknown as typeof fetch;

    const response = await handleLicenseRequest('activate', activateRequest(), bindings, fetcher);
    expect(response.status).toBe(404);
  });
});
