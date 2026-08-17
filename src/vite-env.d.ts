/// <reference types="vite/client" />

interface ImportMetaEnv {
  /** Prod game-server endpoint (wss://demos.colyseus.cloud/prediction); unset in dev. */
  readonly VITE_SERVER_URL?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
