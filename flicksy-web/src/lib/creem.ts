import type { CreemRuntimeConfig } from './environment';

export type CheckoutSource = 'web' | 'app';

type CreemLicenseKey = {
  key?: unknown;
  mode?: unknown;
  product_id?: unknown;
  metadata?: unknown;
  status?: unknown;
};

type CreemCheckout = {
  id?: unknown;
  mode?: unknown;
  status?: unknown;
  product?: unknown;
  product_id?: unknown;
  checkout_url?: unknown;
  license_keys?: unknown;
  metadata?: unknown;
};

export type CompletedCheckout = {
  checkoutID: string;
  licenseKey: string;
};

export async function createCheckout(
  config: CreemRuntimeConfig,
  source: CheckoutSource,
  fetcher: typeof fetch = fetch,
): Promise<string> {
  const response = await fetcher(`${config.apiURL}/v1/checkouts`, {
    method: 'POST',
    headers: requestHeaders(config.apiKey),
    body: JSON.stringify({
      product_id: config.productID,
      request_id: crypto.randomUUID(),
      success_url: `${config.siteURL}/purchase/success`,
      metadata: { source, environment: config.environment },
    }),
  });
  const parsed = await readJSON(response) as CreemCheckout;
  if (!response.ok) throw new Error(readCreemMessage(parsed) ?? 'Checkout is unavailable.');

  const checkoutURL = readString(parsed.checkout_url);
  if (!checkoutURL || !isCreemCheckoutURL(checkoutURL)) {
    throw new Error('Creem returned an invalid checkout URL.');
  }
  return checkoutURL;
}

export async function retrieveCompletedCheckout(
  config: CreemRuntimeConfig,
  checkoutID: string,
  fetcher: typeof fetch = fetch,
): Promise<CompletedCheckout> {
  if (!/^ch(?:k)?_[A-Za-z0-9]+$/.test(checkoutID)) {
    throw new Error('The checkout identifier is invalid.');
  }

  const url = new URL(`${config.apiURL}/v1/checkouts`);
  url.searchParams.set('checkout_id', checkoutID);
  const response = await fetcher(url, { headers: { 'x-api-key': config.apiKey } });
  const parsed = await readJSON(response) as CreemCheckout;
  if (!response.ok) throw new Error(readCreemMessage(parsed) ?? 'The purchase could not be verified.');

  const expectedMode = config.environment === 'test' ? 'test' : 'prod';
  const mode = readString(parsed.mode);
  const status = readString(parsed.status);
  const productID = extractProductID(parsed);
  const returnedCheckoutID = readString(parsed.id);
  const metadata = parsed.metadata && typeof parsed.metadata === 'object'
    ? parsed.metadata as { environment?: unknown; source?: unknown }
    : undefined;
  const source = readString(metadata?.source);
  if (
    returnedCheckoutID !== checkoutID
    || mode !== expectedMode
    || status !== 'completed'
    || productID !== config.productID
    || readString(metadata?.environment) !== config.environment
    || (source !== 'web' && source !== 'app')
  ) {
    throw new Error('The purchase does not match this Flicksy environment.');
  }

  const keys = Array.isArray(parsed.license_keys) ? parsed.license_keys as CreemLicenseKey[] : [];
  const license = keys.find((item) =>
    readString(item.mode) === expectedMode
      && readString(item.product_id) === config.productID
      && readString(item.status) !== 'disabled'
      && Boolean(readString(item.key))
  );
  const licenseKey = readString(license?.key);
  if (!licenseKey) throw new Error('Creem has not issued the Flicksy license yet. Check your receipt and try again.');

  return { checkoutID, licenseKey };
}

export async function verifyRedirectSignature(rawQuery: string, apiKey: string): Promise<boolean> {
  const parts: string[] = [];
  let suppliedSignature = '';

  for (const pair of rawQuery.split('&')) {
    if (!pair) continue;
    const separator = pair.indexOf('=');
    const rawKey = separator >= 0 ? pair.slice(0, separator) : pair;
    const rawValue = separator >= 0 ? pair.slice(separator + 1) : '';
    let key: string;
    let value: string;
    try {
      key = decodeURIComponent(rawKey.replace(/\+/g, ' '));
      value = decodeURIComponent(rawValue.replace(/\+/g, ' '));
    } catch {
      return false;
    }
    if (key === 'signature') {
      suppliedSignature = value;
    } else if (value && value !== 'null') {
      parts.push(`${key}=${value}`);
    }
  }

  if (!/^[a-f0-9]{64}$/i.test(suppliedSignature)) return false;
  parts.push(`salt=${apiKey}`);
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(parts.join('|')));
  const expected = Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, '0')).join('');
  return constantTimeEqual(expected, suppliedSignature.toLowerCase());
}

function requestHeaders(apiKey: string): HeadersInit {
  return {
    accept: 'application/json',
    'content-type': 'application/json',
    'x-api-key': apiKey,
  };
}

async function readJSON(response: Response): Promise<unknown> {
  const text = await response.text();
  if (!text.trim()) return {};
  try {
    return JSON.parse(text);
  } catch {
    return {};
  }
}

function extractProductID(checkout: CreemCheckout): string | undefined {
  const direct = readString(checkout.product_id);
  if (direct) return direct;
  if (typeof checkout.product === 'string') return readString(checkout.product);
  if (checkout.product && typeof checkout.product === 'object') {
    return readString((checkout.product as { id?: unknown }).id);
  }
  return undefined;
}

function readCreemMessage(value: unknown): string | undefined {
  if (!value || typeof value !== 'object') return undefined;
  const record = value as { message?: unknown; error?: unknown };
  if (Array.isArray(record.message)) {
    return record.message.find((item): item is string => typeof item === 'string' && Boolean(item.trim()));
  }
  return readString(record.message) ?? readString(record.error);
}

function readString(value: unknown): string | undefined {
  if (typeof value !== 'string') return undefined;
  const trimmed = value.trim();
  return trimmed || undefined;
}

function isCreemCheckoutURL(value: string): boolean {
  try {
    const url = new URL(value);
    return url.protocol === 'https:' && (url.hostname === 'checkout.creem.io' || url.hostname === 'www.creem.io');
  } catch {
    return false;
  }
}

function constantTimeEqual(left: string, right: string): boolean {
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) {
    difference |= left.charCodeAt(index) ^ right.charCodeAt(index);
  }
  return difference === 0;
}
