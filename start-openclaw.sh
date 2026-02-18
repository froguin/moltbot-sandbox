#!/bin/bash
# Startup script for OpenClaw in Cloudflare Sandbox
# This script:
# 1. Restores config from R2 backup if available
# 2. Runs openclaw onboard --non-interactive to configure from env vars
# 3. Patches config for features onboard doesn't cover (channels, gateway auth)
# 4. Starts the gateway

set -e

if pgrep -f "openclaw gateway" > /dev/null 2>&1; then
    echo "OpenClaw gateway is already running, exiting."
    exit 0
fi

CONFIG_DIR="/root/.openclaw"
CONFIG_FILE="$CONFIG_DIR/openclaw.json"
BACKUP_DIR="/data/moltbot"

echo "Config directory: $CONFIG_DIR"
echo "Backup directory: $BACKUP_DIR"

mkdir -p "$CONFIG_DIR"

# ============================================================
# RESTORE FROM R2 BACKUP
# ============================================================

should_restore_from_r2() {
    local R2_SYNC_FILE="$BACKUP_DIR/.last-sync"
    local LOCAL_SYNC_FILE="$CONFIG_DIR/.last-sync"

    if [ ! -f "$R2_SYNC_FILE" ]; then
        echo "No R2 sync timestamp found, skipping restore"
        return 1
    fi

    if [ ! -f "$LOCAL_SYNC_FILE" ]; then
        echo "No local sync timestamp, will restore from R2"
        return 0
    fi

    R2_TIME=$(cat "$R2_SYNC_FILE" 2>/dev/null)
    LOCAL_TIME=$(cat "$LOCAL_SYNC_FILE" 2>/dev/null)

    echo "R2 last sync: $R2_TIME"
    echo "Local last sync: $LOCAL_TIME"

    R2_EPOCH=$(date -d "$R2_TIME" +%s 2>/dev/null || echo "0")
    LOCAL_EPOCH=$(date -d "$LOCAL_TIME" +%s 2>/dev/null || echo "0")

    if [ "$R2_EPOCH" -gt "$LOCAL_EPOCH" ]; then
        echo "R2 backup is newer, will restore"
        return 0
    else
        echo "Local data is newer or same, skipping restore"
        return 1
    fi
}

# Check for backup data in new openclaw/ prefix first, then legacy clawdbot/ prefix
if [ -f "$BACKUP_DIR/openclaw/openclaw.json" ]; then
    if should_restore_from_r2; then
        echo "Restoring from R2 backup at $BACKUP_DIR/openclaw..."
        # Avoid .last-sync type conflicts (file vs directory) during recursive copy.
        rsync -a --exclude='.last-sync' "$BACKUP_DIR/openclaw/" "$CONFIG_DIR/"
        cp -f "$BACKUP_DIR/.last-sync" "$CONFIG_DIR/.last-sync" 2>/dev/null || true
        echo "Restored config from R2 backup"
    fi
elif [ -f "$BACKUP_DIR/clawdbot/clawdbot.json" ]; then
    # Legacy backup format — migrate .clawdbot data into .openclaw
    if should_restore_from_r2; then
        echo "Restoring from legacy R2 backup at $BACKUP_DIR/clawdbot..."
        rsync -a --exclude='.last-sync' "$BACKUP_DIR/clawdbot/" "$CONFIG_DIR/"
        cp -f "$BACKUP_DIR/.last-sync" "$CONFIG_DIR/.last-sync" 2>/dev/null || true
        # Rename the config file if it has the old name
        if [ -f "$CONFIG_DIR/clawdbot.json" ] && [ ! -f "$CONFIG_FILE" ]; then
            mv "$CONFIG_DIR/clawdbot.json" "$CONFIG_FILE"
        fi
        echo "Restored and migrated config from legacy R2 backup"
    fi
elif [ -f "$BACKUP_DIR/clawdbot.json" ]; then
    # Very old legacy backup format (flat structure)
    if should_restore_from_r2; then
        echo "Restoring from flat legacy R2 backup at $BACKUP_DIR..."
        rsync -a --exclude='.last-sync' "$BACKUP_DIR/" "$CONFIG_DIR/"
        cp -f "$BACKUP_DIR/.last-sync" "$CONFIG_DIR/.last-sync" 2>/dev/null || true
        if [ -f "$CONFIG_DIR/clawdbot.json" ] && [ ! -f "$CONFIG_FILE" ]; then
            mv "$CONFIG_DIR/clawdbot.json" "$CONFIG_FILE"
        fi
        echo "Restored and migrated config from flat legacy R2 backup"
    fi
elif [ -d "$BACKUP_DIR" ]; then
    echo "R2 mounted at $BACKUP_DIR but no backup data found yet"
else
    echo "R2 not mounted, starting fresh"
fi

# Restore workspace from R2 backup if available (only if R2 is newer)
# This includes IDENTITY.md, USER.md, MEMORY.md, memory/, and assets/
WORKSPACE_DIR="/root/clawd"
if [ -d "$BACKUP_DIR/workspace" ] && [ "$(ls -A $BACKUP_DIR/workspace 2>/dev/null)" ]; then
    if should_restore_from_r2; then
        echo "Restoring workspace from $BACKUP_DIR/workspace..."
        mkdir -p "$WORKSPACE_DIR"
        cp -a "$BACKUP_DIR/workspace/." "$WORKSPACE_DIR/"
        echo "Restored workspace from R2 backup"
    fi
fi

# Restore skills from R2 backup if available (only if R2 is newer)
SKILLS_DIR="/root/clawd/skills"
if [ -d "$BACKUP_DIR/skills" ] && [ "$(ls -A $BACKUP_DIR/skills 2>/dev/null)" ]; then
    if should_restore_from_r2; then
        echo "Restoring skills from $BACKUP_DIR/skills..."
        mkdir -p "$SKILLS_DIR"
        cp -a "$BACKUP_DIR/skills/." "$SKILLS_DIR/"
        echo "Restored skills from R2 backup"
    fi
fi

# ============================================================
# ONBOARD (only if no config exists yet)
# ============================================================
if [ ! -f "$CONFIG_FILE" ]; then
    echo "No existing config found, running openclaw onboard..."

    AUTH_ARGS=""
    # Support both new and legacy AI Gateway variable names
    GATEWAY_API_KEY="${CLOUDFLARE_AI_GATEWAY_API_KEY:-$AI_GATEWAY_API_KEY}"
    # Skip placeholder values and fall back to ANTHROPIC_API_KEY
    if [ "$GATEWAY_API_KEY" = "dummy" ] || [ "$GATEWAY_API_KEY" = "dummy-key" ]; then
        echo "Warning: CLOUDFLARE_AI_GATEWAY_API_KEY is a placeholder ('$GATEWAY_API_KEY'), falling back to ANTHROPIC_API_KEY"
        GATEWAY_API_KEY="${ANTHROPIC_API_KEY:-$GATEWAY_API_KEY}"
    fi
    GATEWAY_ACCOUNT_ID="${CF_AI_GATEWAY_ACCOUNT_ID:-$CF_ACCOUNT_ID}"
    GATEWAY_ID="${CF_AI_GATEWAY_GATEWAY_ID}"

    if [ -n "$GATEWAY_API_KEY" ] && [ -n "$GATEWAY_ACCOUNT_ID" ] && [ -n "$GATEWAY_ID" ]; then
        AUTH_ARGS="--auth-choice cloudflare-ai-gateway-api-key \
            --cloudflare-ai-gateway-account-id $GATEWAY_ACCOUNT_ID \
            --cloudflare-ai-gateway-gateway-id $GATEWAY_ID \
            --cloudflare-ai-gateway-api-key $GATEWAY_API_KEY"
    elif [ -n "$ANTHROPIC_API_KEY" ]; then
        AUTH_ARGS="--auth-choice apiKey --anthropic-api-key $ANTHROPIC_API_KEY"
    elif [ -n "$OPENAI_API_KEY" ]; then
        AUTH_ARGS="--auth-choice openai-api-key --openai-api-key $OPENAI_API_KEY"
    fi

    openclaw onboard --non-interactive --accept-risk \
        --mode local \
        $AUTH_ARGS \
        --gateway-port 18789 \
        --gateway-bind lan \
        --skip-channels \
        --skip-skills \
        --skip-health

    echo "Onboard completed"
else
    echo "Using existing config"
fi

# ============================================================
# PATCH CONFIG (channels, gateway auth, trusted proxies)
# ============================================================
# openclaw onboard handles provider/model config, but we need to patch in:
# - Channel config (Telegram, Discord, Slack)
# - Gateway token auth
# - Trusted proxies for sandbox networking
# - Base URL override for legacy AI Gateway path
node << 'EOFPATCH'
const fs = require('fs');

const configPath = '/root/.openclaw/openclaw.json';
console.log('Patching config at:', configPath);
let config = {};

try {
    config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
} catch (e) {
    console.log('Starting with empty config');
}

config.gateway = config.gateway || {};
config.channels = config.channels || {};

// Gateway configuration
config.gateway.port = 18789;
config.gateway.mode = 'local';
config.gateway.trustedProxies = ['10.1.0.0'];

if (process.env.OPENCLAW_GATEWAY_TOKEN) {
    config.gateway.auth = config.gateway.auth || {};
    config.gateway.auth.token = process.env.OPENCLAW_GATEWAY_TOKEN;
}

if (process.env.OPENCLAW_DEV_MODE === 'true') {
    config.gateway.controlUi = config.gateway.controlUi || {};
    config.gateway.controlUi.allowInsecureAuth = true;
}

// Workers AI models can emit malformed tool calls (e.g. memory_search with
// "[object Object]" params) in some OpenAI-compatible paths. Disable memory
// tools by default for workers-ai to prioritize reliable text replies.
// Set OPENCLAW_ENABLE_MEMORY_PLUGIN=true to re-enable memory tools.
{
    const model = process.env.CF_AI_GATEWAY_MODEL || '';
    const isWorkersAI = model.startsWith('workers-ai/');
    const memoryPluginForcedOn = process.env.OPENCLAW_ENABLE_MEMORY_PLUGIN === 'true';
    if (isWorkersAI && !memoryPluginForcedOn) {
        config.plugins = config.plugins || {};
        config.plugins.slots = config.plugins.slots || {};
        config.plugins.slots.memory = 'none';
        console.log('Disabled memory plugin for workers-ai compatibility');
    }
}

// Refresh API keys on all existing providers from current env vars.
// R2 backups may contain stale "dummy-key" or rotated keys.
{
    let freshKey = process.env.CLOUDFLARE_AI_GATEWAY_API_KEY || process.env.AI_GATEWAY_API_KEY;
    // Skip placeholder values
    if (freshKey && (freshKey === 'dummy' || freshKey === 'dummy-key' || freshKey.length < 10)) {
        freshKey = process.env.ANTHROPIC_API_KEY || freshKey;
    }
    if (freshKey && config.models && config.models.providers) {
        for (const [name, provider] of Object.entries(config.models.providers)) {
            if (provider.apiKey && provider.apiKey !== freshKey) {
                provider.apiKey = freshKey;
                console.log('Refreshed apiKey for provider: ' + name);
            }
        }
    }
}

// AI Gateway model override (CF_AI_GATEWAY_MODEL=provider/model-id)
// Adds a provider entry for any AI Gateway provider and sets it as default model.
// Examples:
//   workers-ai/@cf/meta/llama-3.3-70b-instruct-fp8-fast
//   openai/gpt-4o
//   anthropic/claude-sonnet-4-5
if (process.env.CF_AI_GATEWAY_MODEL) {
    const raw = process.env.CF_AI_GATEWAY_MODEL.trim();
    const slashIdx = raw.indexOf('/');
    if (slashIdx <= 0 || slashIdx >= raw.length - 1) {
        console.warn('Invalid CF_AI_GATEWAY_MODEL format (expected provider/model-id): ' + raw);
    } else {
        const gwProvider = raw.substring(0, slashIdx).trim().toLowerCase();
        const modelId = raw.substring(slashIdx + 1).trim();

        // Support both new and legacy variable names
        const accountId = process.env.CF_AI_GATEWAY_ACCOUNT_ID || process.env.CF_ACCOUNT_ID;
        const gatewayId = process.env.CF_AI_GATEWAY_GATEWAY_ID;
        let apiKey = process.env.CLOUDFLARE_AI_GATEWAY_API_KEY || process.env.AI_GATEWAY_API_KEY;
        const apiKeyLooksPlaceholder = !apiKey || apiKey === 'dummy' || apiKey === 'dummy-key' || apiKey.length < 10;
        // Only fall back to ANTHROPIC_API_KEY for anthropic provider.
        // Falling back for non-anthropic providers (e.g. openrouter, groq) can silently set the wrong key.
        if (apiKeyLooksPlaceholder) {
            if (gwProvider === 'anthropic' && process.env.ANTHROPIC_API_KEY && process.env.ANTHROPIC_API_KEY.length >= 10) {
                console.warn('CF AI Gateway API key looks like a placeholder, falling back to ANTHROPIC_API_KEY for anthropic provider');
                apiKey = process.env.ANTHROPIC_API_KEY;
            } else {
                apiKey = '';
                console.warn('CF AI Gateway API key is missing or placeholder for provider=' + gwProvider);
            }
        }
        console.log('AI Gateway model API key: length=' + (apiKey ? apiKey.length : 0) + ' prefix=' + (apiKey ? apiKey.substring(0, 6) + '...' : 'none'));

        let baseUrl;
        if (accountId && gatewayId) {
            baseUrl = 'https://gateway.ai.cloudflare.com/v1/' + accountId + '/' + gatewayId + '/' + gwProvider;
            if (gwProvider === 'workers-ai') baseUrl += '/v1';
        } else if (gwProvider === 'workers-ai' && accountId) {
            baseUrl = 'https://api.cloudflare.com/client/v4/accounts/' + accountId + '/ai/v1';
        }

        if (baseUrl && apiKey) {
            const defaultApi = gwProvider === 'anthropic' ? 'anthropic-messages' : 'openai-completions';
            const forcedApi = (process.env.OPENCLAW_AI_GATEWAY_API || '').trim();
            const api = forcedApi || defaultApi;
            const providerName = 'cf-ai-gw-' + gwProvider;

            config.models = config.models || {};
            config.models.providers = config.models.providers || {};
            config.models.providers[providerName] = {
                baseUrl: baseUrl,
                apiKey: apiKey,
                api: api,
                models: [{ id: modelId, name: modelId, contextWindow: 131072, maxTokens: 8192 }],
            };
            config.agents = config.agents || {};
            config.agents.defaults = config.agents.defaults || {};
            config.agents.defaults.model = { primary: providerName + '/' + modelId };
            console.log('AI Gateway model override: provider=' + providerName + ' model=' + modelId + ' api=' + api + ' via ' + baseUrl);
        } else {
            console.warn('CF_AI_GATEWAY_MODEL set but missing required config (account ID, gateway ID, or API key)');
        }
    }
}

// Telegram configuration
// Overwrite entire channel object to drop stale keys from old R2 backups
// that would fail OpenClaw's strict config validation (see #47)
if (process.env.TELEGRAM_BOT_TOKEN) {
    const dmPolicy = process.env.TELEGRAM_DM_POLICY || 'pairing';
    config.channels.telegram = {
        botToken: process.env.TELEGRAM_BOT_TOKEN,
        enabled: true,
        dmPolicy: dmPolicy,
    };
    if (process.env.TELEGRAM_DM_ALLOW_FROM) {
        config.channels.telegram.allowFrom = process.env.TELEGRAM_DM_ALLOW_FROM.split(',');
    } else if (dmPolicy === 'open') {
        config.channels.telegram.allowFrom = ['*'];
    }
}

// Discord configuration
// Discord uses a nested dm object: dm.policy, dm.allowFrom (per DiscordDmConfig)
if (process.env.DISCORD_BOT_TOKEN) {
    const dmPolicy = process.env.DISCORD_DM_POLICY || 'pairing';
    const dm = { policy: dmPolicy };
    if (dmPolicy === 'open') {
        dm.allowFrom = ['*'];
    }
    config.channels.discord = {
        token: process.env.DISCORD_BOT_TOKEN,
        enabled: true,
        dm: dm,
    };
}

// Slack configuration
if (process.env.SLACK_BOT_TOKEN && process.env.SLACK_APP_TOKEN) {
    const dmPolicy = process.env.SLACK_DM_POLICY || 'pairing';
    const allowFrom = process.env.SLACK_DM_ALLOW_FROM
        ? process.env.SLACK_DM_ALLOW_FROM.split(',').map((id) => id.trim()).filter(Boolean)
        : (dmPolicy === 'open' ? ['*'] : undefined);
    const dm = {
        enabled: true,
        policy: dmPolicy,
        ...(allowFrom ? { allowFrom } : {}),
    };
    config.channels.slack = {
        botToken: process.env.SLACK_BOT_TOKEN,
        appToken: process.env.SLACK_APP_TOKEN,
        enabled: true,
        dm: dm,
    };
}

fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
console.log('Configuration patched successfully');
EOFPATCH

# ============================================================
# START GATEWAY
# ============================================================
echo "Starting OpenClaw Gateway..."
echo "Gateway will be available on port 18789"

rm -f /tmp/openclaw-gateway.lock 2>/dev/null || true
rm -f "$CONFIG_DIR/gateway.lock" 2>/dev/null || true

echo "Dev mode: ${OPENCLAW_DEV_MODE:-false}"

if [ -n "$OPENCLAW_GATEWAY_TOKEN" ]; then
    echo "Starting gateway with token auth..."
    exec openclaw gateway --port 18789 --allow-unconfigured --bind lan --token "$OPENCLAW_GATEWAY_TOKEN"
else
    echo "Starting gateway with device pairing (no token)..."
    exec openclaw gateway --port 18789 --allow-unconfigured --bind lan
fi
