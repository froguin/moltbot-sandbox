import type { Sandbox, Process } from '@cloudflare/sandbox';
import type { MoltbotEnv } from '../types';
import { MOLTBOT_PORT, STARTUP_TIMEOUT_MS } from '../config';
import { buildEnvVars } from './env';
import { mountR2Storage } from './r2';

// Prevent concurrent requests from starting duplicate gateway processes.
// This lock is process-local to the current Worker isolate.
let gatewayStartupPromise: Promise<Process> | null = null;
let gatewayRecoveryPromise: Promise<void> | null = null;

const GATEWAY_START_COMMAND = `/bin/bash -lc '/usr/local/bin/start-openclaw.sh || true; node -e "const fs=require(\\\"fs\\\");const p=\\\"/root/.openclaw/openclaw.json\\\";let c={};try{c=JSON.parse(fs.readFileSync(p,\\\"utf8\\\"))}catch{};c.gateway=c.gateway||{};c.gateway.controlUi=c.gateway.controlUi||{};c.gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback=true;if(c.channels&&c.channels.slack&&c.channels.slack.dm){delete c.channels.slack.dm;}fs.mkdirSync(\\\"/root/.openclaw\\\",{recursive:true});fs.writeFileSync(p,JSON.stringify(c,null,2));"; openclaw doctor --fix >/dev/null 2>&1 || true; if [ -n "$OPENCLAW_GATEWAY_TOKEN" ]; then exec openclaw gateway --port 18789 --allow-unconfigured --bind lan --token "$OPENCLAW_GATEWAY_TOKEN"; else exec openclaw gateway --port 18789 --allow-unconfigured --bind lan; fi'`;

function isGatewayProcessCommand(command: string): boolean {
  const isGatewayProcess =
    command.includes('start-openclaw.sh') ||
    command.includes('openclaw gateway') ||
    // Legacy: match old startup script during transition
    command.includes('start-moltbot.sh') ||
    command.includes('clawdbot gateway');
  const isCliCommand =
    command.includes('openclaw devices') ||
    command.includes('openclaw --version') ||
    command.includes('openclaw onboard') ||
    command.includes('clawdbot devices') ||
    command.includes('clawdbot --version');
  return isGatewayProcess && !isCliCommand;
}

/**
 * Find an existing OpenClaw gateway process
 *
 * @param sandbox - The sandbox instance
 * @returns The process if found and running/starting, null otherwise
 */
export async function findExistingMoltbotProcess(sandbox: Sandbox): Promise<Process | null> {
  try {
    const processes = await sandbox.listProcesses();
    for (const proc of processes) {
      if (isGatewayProcessCommand(proc.command)) {
        if (proc.status === 'starting' || proc.status === 'running') {
          return proc;
        }
      }
    }
  } catch (e) {
    console.log('Could not list processes:', e);
  }
  return null;
}

/**
 * Start the gateway process if missing, without waiting for port readiness.
 * Useful for lightweight kick-off paths such as loading/status endpoints.
 */
export async function kickStartMoltbotGateway(sandbox: Sandbox, env: MoltbotEnv): Promise<Process | null> {
  await mountR2Storage(sandbox, env);

  const existingProcess = await findExistingMoltbotProcess(sandbox);
  if (existingProcess) {
    return existingProcess;
  }

  const envVars = buildEnvVars(env);
  const command = GATEWAY_START_COMMAND;

  try {
    const process = await sandbox.startProcess(command, {
      env: Object.keys(envVars).length > 0 ? envVars : undefined,
    });
    console.log('Kickstarted gateway process:', process.id, 'status:', process.status);
    return process;
  } catch (err) {
    console.error('Failed to kickstart gateway process:', err);
    return null;
  }
}

/**
 * Force-recover gateway by killing stuck gateway-like processes and starting a new one.
 * This path is designed for lightweight recovery loops (e.g., /api/status polling).
 */
export async function recoverMoltbotGateway(sandbox: Sandbox, env: MoltbotEnv): Promise<void> {
  if (gatewayRecoveryPromise) {
    console.log('Gateway recovery already in progress, waiting for existing attempt...');
    return gatewayRecoveryPromise;
  }

  gatewayRecoveryPromise = (async () => {
    try {
      const processes = await sandbox.listProcesses();
      const candidates = processes.filter(
        (proc) =>
          isGatewayProcessCommand(proc.command) &&
          (proc.status === 'starting' || proc.status === 'running'),
      );

      for (const proc of candidates) {
        try {
          console.log('Killing stuck gateway process:', proc.id, proc.command);
          await proc.kill();
        } catch (killErr) {
          console.log('Failed to kill stuck gateway process:', proc.id, killErr);
        }
      }

      await kickStartMoltbotGateway(sandbox, env);
    } catch (err) {
      console.error('Gateway recovery failed:', err);
    }
  })();

  try {
    await gatewayRecoveryPromise;
  } finally {
    gatewayRecoveryPromise = null;
  }
}

/**
 * Ensure the OpenClaw gateway is running
 *
 * This will:
 * 1. Mount R2 storage if configured
 * 2. Check for an existing gateway process
 * 3. Wait for it to be ready, or start a new one
 *
 * @param sandbox - The sandbox instance
 * @param env - Worker environment bindings
 * @returns The running gateway process
 */
export async function ensureMoltbotGateway(sandbox: Sandbox, env: MoltbotEnv): Promise<Process> {
  if (gatewayStartupPromise) {
    console.log('Gateway startup already in progress, waiting for existing attempt...');
    return gatewayStartupPromise;
  }

  gatewayStartupPromise = ensureMoltbotGatewayInternal(sandbox, env);
  try {
    return await gatewayStartupPromise;
  } finally {
    gatewayStartupPromise = null;
  }
}

async function ensureMoltbotGatewayInternal(sandbox: Sandbox, env: MoltbotEnv): Promise<Process> {
  // Mount R2 storage for persistent data (non-blocking if not configured)
  // R2 is used as a backup - the startup script will restore from it on boot
  await mountR2Storage(sandbox, env);

  // Check if gateway is already running or starting
  const existingProcess = await findExistingMoltbotProcess(sandbox);
  if (existingProcess) {
    console.log(
      'Found existing gateway process:',
      existingProcess.id,
      'status:',
      existingProcess.status,
    );

    // Always use full startup timeout - a process can be "running" but not ready yet
    // (e.g., just started by another concurrent request). Using a shorter timeout
    // causes race conditions where we kill processes that are still initializing.
    try {
      console.log('Waiting for gateway on port', MOLTBOT_PORT, 'timeout:', STARTUP_TIMEOUT_MS);
      await existingProcess.waitForPort(MOLTBOT_PORT, { mode: 'tcp', timeout: STARTUP_TIMEOUT_MS });
      console.log('Gateway is reachable');
      return existingProcess;
      // eslint-disable-next-line no-unused-vars
    } catch (_e) {
      // Timeout waiting for port - process is likely dead or stuck, kill and restart
      console.log('Existing process not reachable after full timeout, killing and restarting...');
      try {
        await existingProcess.kill();
      } catch (killError) {
        console.log('Failed to kill process:', killError);
      }
    }
  }

  // Start a new OpenClaw gateway
  console.log('Starting new OpenClaw gateway...');
  const envVars = buildEnvVars(env);
  const command = GATEWAY_START_COMMAND;

  console.log('Starting process with command:', command);
  console.log('Environment vars being passed:', Object.keys(envVars));

  let process: Process;
  try {
    process = await sandbox.startProcess(command, {
      env: Object.keys(envVars).length > 0 ? envVars : undefined,
    });
    console.log('Process started with id:', process.id, 'status:', process.status);
  } catch (startErr) {
    console.error('Failed to start process:', startErr);
    throw startErr;
  }

  // Wait for the gateway to be ready
  try {
    console.log('[Gateway] Waiting for OpenClaw gateway to be ready on port', MOLTBOT_PORT);
    await process.waitForPort(MOLTBOT_PORT, { mode: 'tcp', timeout: STARTUP_TIMEOUT_MS });
    console.log('[Gateway] OpenClaw gateway is ready!');

    const logs = await process.getLogs();
    if (logs.stdout) console.log('[Gateway] stdout:', logs.stdout);
    if (logs.stderr) console.log('[Gateway] stderr:', logs.stderr);
  } catch (e) {
    console.error('[Gateway] waitForPort failed:', e);
    try {
      const logs = await process.getLogs();
      console.error('[Gateway] startup failed. Stderr:', logs.stderr);
      console.error('[Gateway] startup failed. Stdout:', logs.stdout);
      throw new Error(`OpenClaw gateway failed to start. Stderr: ${logs.stderr || '(empty)'}`, {
        cause: e,
      });
    } catch (logErr) {
      console.error('[Gateway] Failed to get logs:', logErr);
      throw e;
    }
  }

  // Verify gateway is actually responding
  console.log('[Gateway] Verifying gateway health...');

  return process;
}
