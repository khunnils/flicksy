import { afterEach, expect, it, vi } from 'vitest';
import { analyticsAllowed, analyticsPage, setupAnalytics } from './analytics';

const appID = '11111111-2222-3333-4444-555555555555';
function browser({ path = '/', disabled = false, dnt = '0', gpc = false } = {}) {
  const listeners: Record<string, (event: unknown) => void> = {};
  const toggle = { checked: false, disabled: false, addEventListener: (name: string, fn: (event: unknown) => void) => { listeners[name] = fn; } };
  const storage = new Map(disabled ? [['flicksy.analytics.disabled', 'true']] : []);
  vi.stubGlobal('navigator', { doNotTrack: dnt, globalPrivacyControl: gpc });
  vi.stubGlobal('location', { pathname: path, search: '?license=SECRET', hash: '#SECRET' });
  vi.stubGlobal('localStorage', { getItem: (key: string) => storage.get(key) ?? null, setItem: (key: string, value: string) => storage.set(key, value) });
  vi.stubGlobal('document', { querySelector: () => toggle, referrer: 'https://example.com/SECRET', addEventListener: toggle.addEventListener });
  vi.stubGlobal('window', { addEventListener: toggle.addEventListener });
  const fetch = vi.fn().mockResolvedValue(new Response());
  vi.stubGlobal('fetch', fetch);
  return { fetch, toggle, listeners };
}

afterEach(() => vi.unstubAllGlobals());

it('only recognizes public routes', () => {
  expect(analyticsPage('/docs/preview/')).toBe('/docs/preview');
  for (const path of ['/purchase/success', '/files/private.jpg', '/?secret=value', '/docs/private']) {
    expect(analyticsPage(path)).toBeUndefined();
  }
});

it('respects opt-out and browser signals', () => {
  expect(analyticsAllowed(null, null)).toBe(true);
  expect(analyticsAllowed('true', null)).toBe(false);
  expect(analyticsAllowed(null, '1')).toBe(false);
  expect(analyticsAllowed(null, null, true)).toBe(false);
});

it.each([{ disabled: true }, { dnt: '1' }, { gpc: true }, { path: '/purchase/success' }])('does not send when blocked: %j', async (options) => {
  const { fetch } = browser(options);
  setupAnalytics(appID, true);
  await new Promise(resolve => setTimeout(resolve, 20));
  expect(fetch).not.toHaveBeenCalled();
});

it('does not send without a configured ID or readable preferences', async () => {
  const { fetch } = browser();
  setupAnalytics('', true);
  vi.stubGlobal('localStorage', { getItem: () => { throw new Error('blocked'); } });
  setupAnalytics(appID, true);
  await new Promise(resolve => setTimeout(resolve, 20));
  expect(fetch).not.toHaveBeenCalled();
});

it('sends only an allowed page, without HTTP referrers or credentials', async () => {
  const { fetch } = browser({ path: '/docs/preview' });
  setupAnalytics(appID, true);
  await vi.waitFor(() => expect(fetch).toHaveBeenCalledOnce());
  const [url, request] = fetch.mock.calls[0];
  expect(url).toBe('https://nom.telemetrydeck.com/v2/');
  expect(request.referrerPolicy).toBe('no-referrer');
  expect(request.credentials).toBe('omit');
  const [body] = JSON.parse(request.body);
  expect(body.payload).toEqual({ page: '/docs/preview' });
  expect(body.type).toBe('com.flicksy.Web.pageViewed');
  expect(body.isTestMode).toBe(true);
  expect(request.body).not.toContain('SECRET');
});

it('cancels in-flight requests when disabled', async () => {
  const { fetch, toggle, listeners } = browser();
  setupAnalytics(appID, false);
  await vi.waitFor(() => expect(fetch).toHaveBeenCalledOnce());
  const signal = fetch.mock.calls[0][1].signal as AbortSignal;
  toggle.checked = false;
  listeners.change({});
  expect(signal.aborted).toBe(true);
  expect(localStorage.getItem('flicksy.analytics.disabled')).toBe('true');
});
