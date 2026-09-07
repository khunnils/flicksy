export type FlicksyEnvironment = 'test' | 'production';

export type FlicksyBindings = {
  FLICKSY_ENVIRONMENT?: string;
  FLICKSY_SITE_URL?: string;
  FLICKSY_DIRECT_DOWNLOAD_URL?: string;
  FLICKSY_APP_STORE_URL?: string;
};

export type PublicRuntimeConfig = {
  environment: FlicksyEnvironment;
  siteURL: string;
  directDownloadURL: string;
  appStoreURL?: string;
};

export function readPublicConfig(bindings: FlicksyBindings): PublicRuntimeConfig {
  const environment = readEnvironment(bindings.FLICKSY_ENVIRONMENT);
  const siteURL = readHTTPSURL(bindings.FLICKSY_SITE_URL, 'FLICKSY_SITE_URL');
  const directDownloadURL = readHTTPSURL(
    bindings.FLICKSY_DIRECT_DOWNLOAD_URL,
    'FLICKSY_DIRECT_DOWNLOAD_URL',
  );
  const appStoreURL = readOptionalHTTPSURL(bindings.FLICKSY_APP_STORE_URL);

  return { environment, siteURL, directDownloadURL, appStoreURL };
}

export function configurationReadiness(bindings: FlicksyBindings) {
  let site = false;
  try {
    const config = readPublicConfig(bindings);
    site = true;
    if (config.environment === 'production' && !config.appStoreURL) {
      site = false;
    }
  } catch {
    site = false;
  }

  return { site, commerce: site };
}

function readEnvironment(value: string | undefined): FlicksyEnvironment {
  const normalized = value?.trim();
  if (normalized === 'test' || normalized === 'production') return normalized;
  throw new Error('FLICKSY_ENVIRONMENT must be test or production.');
}

function readRequired(value: string | undefined, name: string): string {
  const normalized = value?.trim();
  if (!normalized || isPlaceholder(normalized)) throw new Error(`${name} is not configured.`);
  return normalized;
}

function readHTTPSURL(value: string | undefined, name: string): string {
  const normalized = readRequired(value, name);
  let url: URL;
  try {
    url = new URL(normalized);
  } catch {
    throw new Error(`${name} must be a valid URL.`);
  }
  if (url.protocol !== 'https:') throw new Error(`${name} must use HTTPS.`);
  return url.toString().replace(/\/$/, '');
}

function readOptionalHTTPSURL(value: string | undefined): string | undefined {
  const normalized = value?.trim();
  if (!normalized || isPlaceholder(normalized)) return undefined;
  return readHTTPSURL(normalized, 'FLICKSY_APP_STORE_URL');
}

function isPlaceholder(value: string): boolean {
  return /REPLACE|XXXXX|YOUR_APP_ID|id0{4,}/i.test(value);
}
