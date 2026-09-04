import { describe, expect, it } from 'vitest';
import { configurationReadiness, readCreemConfig, readPublicConfig, type FlicksyBindings } from './environment';

const testBindings: FlicksyBindings = {
  FLICKSY_ENVIRONMENT: 'test',
  FLICKSY_SITE_URL: 'https://preview.flicksy.me',
  FLICKSY_DIRECT_DOWNLOAD_URL: 'https://example.com/Flicksy-Test.dmg',
  FLICKSY_APP_STORE_URL: '',
  CREEM_API_KEY: 'creem_test_unit_test_key',
  CREEM_PRODUCT_ID: 'prod_test123',
};

describe('environment configuration', () => {
  it('selects the Creem test API for the test environment', () => {
    expect(readCreemConfig(testBindings)).toMatchObject({
      environment: 'test',
      apiURL: 'https://test-api.creem.io',
      productID: 'prod_test123',
    });
  });

  it('rejects test keys in production', () => {
    expect(() => readCreemConfig({
      ...testBindings,
      FLICKSY_ENVIRONMENT: 'production',
      FLICKSY_SITE_URL: 'https://flicksy.me',
      FLICKSY_APP_STORE_URL: 'https://apps.apple.com/app/id1234567890',
    })).toThrow('production environment cannot use a Creem test API key');
  });

  it('requires HTTPS public URLs', () => {
    expect(() => readPublicConfig({
      ...testBindings,
      FLICKSY_SITE_URL: 'http://preview.flicksy.me',
    })).toThrow('FLICKSY_SITE_URL must use HTTPS');
  });

  it('does not report a production site ready without an App Store URL', () => {
    expect(configurationReadiness({
      ...testBindings,
      FLICKSY_ENVIRONMENT: 'production',
      FLICKSY_SITE_URL: 'https://flicksy.me',
      FLICKSY_APP_STORE_URL: '',
      CREEM_API_KEY: 'creem_live_unit_test_key',
      CREEM_PRODUCT_ID: 'prod_live123',
    })).toEqual({ site: false, commerce: true });
  });
});
