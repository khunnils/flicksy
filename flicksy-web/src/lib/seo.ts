export const SITE_URL = 'https://flicksy.me';

/** Keep tracking parameters, fragments, and preview origins out of search URLs. */
export function canonicalURL(path: string): string {
  const pathname = new URL(path, SITE_URL).pathname.replace(/\/+$/, '') || '/';
  return `${SITE_URL}${pathname}`;
}

export function serializeJsonLd(value: unknown): string {
  return JSON.stringify(value).replace(/</g, '\\u003c');
}
