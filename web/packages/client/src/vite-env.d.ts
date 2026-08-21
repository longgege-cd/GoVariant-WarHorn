/// <reference types="vite/client" />

interface ImportMetaEnv {
  /** 部署时指定后端地址（Socket.IO 服务），缺省回退 localhost:3000 */
  readonly VITE_SERVER_URL?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}