import TelemetryDeck from '@telemetrydeck/sdk';

export const analyticsPreferenceKey = 'flicksy.analytics.disabled';
const pages = new Set(['/', '/docs', '/privacy', '/license', '/refunds',
  '/docs/getting_started', '/docs/browsing', '/docs/preview', '/docs/audio',
  '/docs/organize', '/docs/keyboard_shortcuts', '/docs/trial_and_license']);
const events = new Set([
  'com.flicksy.Web.downloadClicked',
  'com.flicksy.Web.purchaseClicked',
  'com.flicksy.Web.appStoreClicked',
]);

// An allowlist avoids leaking arbitrary path segments, queries, fragments or
// purchase callback data. Checkout/success and unknown pages send nothing.
export function analyticsPage(pathname: string): string | undefined {
  const page = pathname.replace(/\/$/, '') || '/';
  return pages.has(page) ? page : undefined;
}

export function analyticsAllowed(disabled: string | null, dnt: string | null, gpc?: boolean): boolean {
  return disabled !== 'true' && dnt !== '1' && gpc !== true;
}

export function setupAnalytics(appID: string, testMode: boolean) {
  const privacyNavigator = navigator as Navigator & { globalPrivacyControl?: boolean };
  const browserBlocks = navigator.doNotTrack === '1' || privacyNavigator.globalPrivacyControl === true;
  let disabled = true;
  try { disabled = !analyticsAllowed(localStorage.getItem(analyticsPreferenceKey), navigator.doNotTrack, privacyNavigator.globalPrivacyControl); }
  catch { /* Fail closed if the preference cannot be read. */ }
  const page = analyticsPage(location.pathname);
  const configured = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(appID);
  let controller = new AbortController();

  class WebsiteTelemetry extends TelemetryDeck {
    // Keep click events alive across navigation, omit cookies and the HTTP
    // referrer, and recheck consent after the SDK's asynchronous hashing.
    _post(body: unknown): Promise<Response> {
      if (disabled) return Promise.resolve(new Response(null, { status: 204 }));
      return fetch('https://nom.telemetrydeck.com/v2/', {
        method: 'POST', mode: 'cors', credentials: 'omit', referrerPolicy: 'no-referrer',
        headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
        keepalive: true, signal: controller.signal,
      });
    }
  }

  let client: WebsiteTelemetry | undefined;
  function send(event: string) {
    if (disabled || !configured || !page) return;
    try {
      // No persistent visitor identifier or cookies. Counts represent page
      // visits, not distinct people across pages or returning visitors.
      client ??= new WebsiteTelemetry({ appID, clientUser: crypto.randomUUID(), testMode });
      void client.signal(event, { page }).catch(() => {});
    } catch { /* Analytics must never interrupt browsing or checkout. */ }
  }

  const toggle = document.querySelector<HTMLInputElement>('#analytics-enabled');
  if (toggle) {
    toggle.checked = !disabled;
    toggle.disabled = browserBlocks;
    toggle.addEventListener('change', () => {
      disabled = !toggle.checked || browserBlocks;
      try { localStorage.setItem(analyticsPreferenceKey, String(disabled)); }
      catch { disabled = true; toggle.checked = false; }
      controller.abort();
      controller = new AbortController();
      client = undefined;
      if (!disabled) send('com.flicksy.Web.pageViewed');
    });
  }
  window.addEventListener('storage', (event) => {
    if (event.key !== analyticsPreferenceKey && event.key !== null) return;
    try { disabled = !analyticsAllowed(localStorage.getItem(analyticsPreferenceKey), navigator.doNotTrack, privacyNavigator.globalPrivacyControl); }
    catch { disabled = true; }
    if (disabled) controller.abort();
    else controller = new AbortController();
    if (toggle) toggle.checked = !disabled;
  });
  document.addEventListener('click', (event) => {
    const element = event.target instanceof Element ? event.target.closest('[data-analytics-event]') : null;
    const name = element?.getAttribute('data-analytics-event');
    if (name && events.has(name)) send(name);
  });
  send('com.flicksy.Web.pageViewed');
}
