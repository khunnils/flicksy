declare module 'cloudflare:workers' {
  export const env: {
    FLICKSY_ENVIRONMENT?: string;
    FLICKSY_TELEMETRYDECK_APP_ID?: string;
    FLICKSY_SITE_URL?: string;
    FLICKSY_DIRECT_DOWNLOAD_URL?: string;
    FLICKSY_APP_STORE_URL?: string;
    CREEM_API_KEY?: string;
    CREEM_PRODUCT_ID?: string;
  };
}
