import { describe, expect, it } from 'vitest';
import { configurationReadiness, readPublicConfig, type FlicksyBindings } from './environment';

const testBindings: FlicksyBindings = {
  FLICKSY_ENVIRONMENT: 'test',
  FLICKSY_SITE_URL: 'https://preview.flicksy.me',
  FLICKSY_DIRECT_DOWNLOAD_URL: 'https://example.com/Flicksy-Test.dmg',
  FLICKSY_APP_STORE_URL: '',
};

describe('environment configuration', () => {
  it('allows an App Store listing to be unavailable in test', () => {
    expect(readPublicConfig(testBindings).appStoreURL).toBeUndefined();
  });

  it('requires HTTPS public URLs', () => {
    expect(() => readPublicConfig({ ...testBindings, FLICKSY_SITE_URL: 'http://preview.flicksy.me' }))
      .toThrow('FLICKSY_SITE_URL must use HTTPS');
  });

  it('does not report a production site ready without an App Store URL', () => {
    expect(configurationReadiness({
      ...testBindings,
      FLICKSY_ENVIRONMENT: 'production',
      FLICKSY_SITE_URL: 'https://flicksy.me',
    })).toEqual({ site: false, commerce: false });
  });
});
