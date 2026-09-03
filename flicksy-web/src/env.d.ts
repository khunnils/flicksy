declare module 'cloudflare:workers' {
  export const env: {
    CREEM_API_KEY?: string;
    CREEM_PRODUCT_ID?: string;
  };
}
