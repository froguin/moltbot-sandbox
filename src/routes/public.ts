import { Hono } from 'hono';
import type { AppEnv } from '../types';
import { MOLTBOT_PORT } from '../config';
import { ensureMoltbotGateway, findExistingMoltbotProcess } from '../gateway';

/**
 * Public routes - NO Cloudflare Access authentication required
 *
 * These routes are mounted BEFORE the auth middleware is applied.
 * Includes: health checks, static assets, and public API endpoints.
 */
const publicRoutes = new Hono<AppEnv>();
type StatusPayload = {
  ok: boolean;
  status: 'running' | 'not_running' | 'not_responding' | 'error';
  processId?: string;
  error?: string;
};
let statusCache: { expiresAt: number; payload: StatusPayload } | null = null;

// GET /sandbox-health - Health check endpoint
publicRoutes.get('/sandbox-health', (c) => {
  return c.json({
    status: 'ok',
    service: 'moltbot-sandbox',
    gateway_port: MOLTBOT_PORT,
  });
});

// GET /logo.png - Serve logo from ASSETS binding
publicRoutes.get('/logo.png', (c) => {
  return c.env.ASSETS.fetch(c.req.raw);
});

// GET /logo-small.png - Serve small logo from ASSETS binding
publicRoutes.get('/logo-small.png', (c) => {
  return c.env.ASSETS.fetch(c.req.raw);
});

// GET /api/status - Public health check for gateway status (no auth required)
publicRoutes.get('/api/status', async (c) => {
  if (statusCache && statusCache.expiresAt > Date.now()) {
    return c.json(statusCache.payload);
  }

  const sandbox = c.get('sandbox');

  try {
    const process = await findExistingMoltbotProcess(sandbox);
    if (!process) {
      c.executionCtx.waitUntil(
        ensureMoltbotGateway(sandbox, c.env).catch((err: Error) => {
          console.error('[STATUS] Background gateway start failed:', err);
        }),
      );
      const payload: StatusPayload = { ok: false, status: 'not_running' };
      statusCache = { payload, expiresAt: Date.now() + 1500 };
      return c.json(payload);
    }

    // Keep this endpoint lightweight because the loading page polls frequently.
    // Even if process.status says "running", verify the gateway port briefly
    // to avoid false-ready loops when the process is unhealthy.
    try {
      await process.waitForPort(18789, { mode: 'tcp', timeout: 600 });
      const payload: StatusPayload = { ok: true, status: 'running', processId: process.id };
      statusCache = { payload, expiresAt: Date.now() + 1500 };
      return c.json(payload);
    } catch {
      c.executionCtx.waitUntil(
        ensureMoltbotGateway(sandbox, c.env).catch((err: Error) => {
          console.error('[STATUS] Recovery gateway start failed:', err);
        }),
      );
      const payload: StatusPayload = { ok: false, status: 'not_responding', processId: process.id };
      statusCache = { payload, expiresAt: Date.now() + 1500 };
      return c.json(payload);
    }
  } catch (err) {
    const payload: StatusPayload = {
      ok: false,
      status: 'error',
      error: err instanceof Error ? err.message : 'Unknown error',
    };
    statusCache = { payload, expiresAt: Date.now() + 1000 };
    return c.json(payload);
  }
});

// GET /_admin/assets/* - Admin UI static assets (CSS, JS need to load for login redirect)
// Assets are built to dist/client with base "/_admin/"
publicRoutes.get('/_admin/assets/*', async (c) => {
  const url = new URL(c.req.url);
  // Rewrite /_admin/assets/* to /assets/* for the ASSETS binding
  const assetPath = url.pathname.replace('/_admin/assets/', '/assets/');
  const assetUrl = new URL(assetPath, url.origin);
  return c.env.ASSETS.fetch(new Request(assetUrl.toString(), c.req.raw));
});

export { publicRoutes };
