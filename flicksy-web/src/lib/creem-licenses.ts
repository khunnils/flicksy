import { readCreemConfig, type CreemRuntimeConfig, type FlicksyBindings } from './environment';

export const licenseActions = ['activate', 'validate', 'deactivate'] as const;

export type LicenseAction = (typeof licenseActions)[number];

export type LicenseErrorCode = 'invalid' | 'limit' | 'not_found' | 'service';

export type LicenseProxyResponse = {
  ok: boolean;
  status?: string;
  instance_id?: string;
  created_at?: string;
  activation_usage?: number;
  activation_limit?: number | null;
  error?: string;
  error_code?: LicenseErrorCode;
};

export type CreemEnv = FlicksyBindings;

type LicenseRequestBody = {
  key?: unknown;
  instance_name?: unknown;
  instance_id?: unknown;
};

type CreemLicenseInstance = {
  id?: unknown;
  name?: unknown;
};

type CreemLicense = {
  mode?: unknown;
  status?: unknown;
  product_id?: unknown;
  created_at?: unknown;
  activation?: unknown;
  activation_limit?: unknown;
  instance?: unknown;
  message?: unknown;
  error?: unknown;
};

type CreemErrorBody = {
  status?: unknown;
  error?: unknown;
  message?: unknown;
};

export function isLicenseAction(value: string): value is LicenseAction {
  return (licenseActions as readonly string[]).includes(value);
}

export async function handleLicenseRequest(
  action: string,
  request: Request,
  env: CreemEnv,
  fetcher: typeof fetch = fetch,
): Promise<Response> {
  if (!isLicenseAction(action)) {
    return json(
      { ok: false, error: 'Unknown license action.', error_code: 'invalid' },
      404,
    );
  }

  if (request.method !== 'POST') {
    return json(
      { ok: false, error: 'Use POST to manage licenses.', error_code: 'invalid' },
      405,
    );
  }

  let config: CreemRuntimeConfig;
  try {
    config = readCreemConfig(env);
  } catch {
    return json(
      { ok: false, error: 'Licensing is not configured.', error_code: 'service' },
      500,
    );
  }

  let body: LicenseRequestBody;
  try {
    body = (await request.json()) as LicenseRequestBody;
  } catch {
    return json(
      { ok: false, error: 'Expected a JSON license request.', error_code: 'invalid' },
      400,
    );
  }

  const key = readString(body.key);
  if (!key) {
    return json(
      { ok: false, error: 'A license key is required.', error_code: 'invalid' },
      400,
    );
  }

  const payload: Record<string, string> = { key };
  if (action === 'activate') {
    const instanceName = readString(body.instance_name);
    if (!instanceName) {
      return json(
        { ok: false, error: 'An instance name is required.', error_code: 'invalid' },
        400,
      );
    }
    payload.instance_name = instanceName;
  } else {
    const instanceId = readString(body.instance_id);
    if (!instanceId) {
      return json(
        { ok: false, error: 'An instance id is required.', error_code: 'invalid' },
        400,
      );
    }
    payload.instance_id = instanceId;
  }

  const creemUrl = `${config.apiURL}/v1/licenses/${action}`;
  let creemResponse: Response;
  try {
    creemResponse = await fetcher(creemUrl, {
      method: 'POST',
      headers: {
        accept: 'application/json',
        'content-type': 'application/json',
        'x-api-key': config.apiKey,
      },
      body: JSON.stringify(payload),
    });
  } catch {
    return json(
      {
        ok: false,
        error: 'The licensing service is unavailable. Try again in a moment.',
        error_code: 'service',
      },
      502,
    );
  }

  const rawText = await creemResponse.text();
  const parsed = parseJson(rawText);

  if (!creemResponse.ok) {
    return mappedCreemError(creemResponse.status, parsed, action);
  }

  const license = (parsed ?? {}) as CreemLicense;
  const productId = readString(license.product_id);
  const mode = readString(license.mode);
  const expectedMode = config.environment === 'test' ? 'test' : 'prod';
  if (productId !== config.productID || mode !== expectedMode) {
    return json(
      { ok: false, error: 'This key is not a Flicksy license.', error_code: 'invalid' },
      404,
    );
  }

  const status = readString(license.status);
  if (status === 'expired' || status === 'disabled') {
    return json(
      {
        ok: false,
        status,
        error: action === 'validate'
          ? 'This license is no longer valid.'
          : 'This license could not be activated.',
        error_code: 'invalid',
      },
      action === 'validate' ? 410 : 400,
    );
  }

  const instanceId = extractInstanceId(license.instance, readString(body.instance_name))
    ?? (action !== 'activate' ? readString(body.instance_id) : undefined);
  if (action !== 'deactivate' && !instanceId) {
    return json(
      { ok: false, error: 'The license response was incomplete. Please try again.', error_code: 'service' },
      502,
    );
  }

  return json({
    ok: true,
    status: status ?? undefined,
    instance_id: instanceId,
    created_at: readString(license.created_at),
    activation_usage: readNumber(license.activation),
    activation_limit: readLimit(license.activation_limit),
  });
}

function mappedCreemError(status: number, parsed: unknown, action: LicenseAction): Response {
  const errorBody = (parsed ?? {}) as CreemErrorBody;
  const message = firstMessage(errorBody.message)
    ?? readString(errorBody.error)
    ?? defaultErrorMessage(status, action);
  const lower = message.toLowerCase();

  if (status === 403 || lower.includes('activation limit')) {
    return json(
      { ok: false, error: message, error_code: 'limit' },
      403,
    );
  }
  if (status === 404) {
    return json(
      { ok: false, error: message, error_code: 'not_found' },
      404,
    );
  }
  if (status === 410) {
    return json(
      { ok: false, error: message, error_code: 'invalid' },
      410,
    );
  }
  if (status >= 500) {
    return json(
      { ok: false, error: message, error_code: 'service' },
      502,
    );
  }
  return json(
    { ok: false, error: message, error_code: 'invalid' },
    status >= 400 && status < 500 ? status : 400,
  );
}

function defaultErrorMessage(status: number, action: LicenseAction): string {
  if (status === 403) return 'This license is already active on the maximum number of Macs.';
  if (status === 404) return 'This license could not be found.';
  if (status === 410) return 'This license is no longer valid.';
  if (action === 'activate') return 'This license could not be activated.';
  if (action === 'deactivate') return 'This Mac could not be deactivated.';
  return 'This license is no longer valid.';
}

function extractInstanceId(instance: unknown, instanceName?: string): string | undefined {
  if (!instance) return undefined;
  const items = Array.isArray(instance) ? instance : [instance];
  const records = items.filter((item): item is CreemLicenseInstance => typeof item === 'object' && item !== null);
  if (instanceName) {
    const named = records.find((item) => readString(item.name) === instanceName);
    const namedId = readString(named?.id);
    if (namedId) return namedId;
  }
  return readString(records.at(-1)?.id);
}

function firstMessage(message: unknown): string | undefined {
  if (typeof message === 'string' && message.trim()) return message.trim();
  if (Array.isArray(message)) {
    const first = message.find((item) => typeof item === 'string' && item.trim());
    if (typeof first === 'string') return first.trim();
  }
  return undefined;
}

function parseJson(text: string): unknown {
  if (!text.trim()) return undefined;
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}

function readString(value: unknown): string | undefined {
  if (typeof value !== 'string') return undefined;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

function readNumber(value: unknown): number | undefined {
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (typeof value === 'string' && value.trim()) {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) return parsed;
  }
  return undefined;
}

function readLimit(value: unknown): number | null | undefined {
  if (value === null) return null;
  return readNumber(value);
}

function json(body: LicenseProxyResponse, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8' },
  });
}
