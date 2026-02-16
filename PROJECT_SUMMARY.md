# Moltbot Sandbox 프로젝트 요약

## 프로젝트 개요

OpenClaw (구 Moltbot/Clawdbot)를 Cloudflare Sandbox 컨테이너에서 실행하는 Cloudflare Worker 프로젝트입니다.

**주요 기능:**
- OpenClaw 게이트웨이 프록시 (웹 UI + WebSocket)
- `/_admin/` 경로의 관리자 UI (디바이스 관리)
- `/api/*` API 엔드포인트 (디바이스 페어링)
- `/debug/*` 디버그 엔드포인트

## 아키텍처

```
브라우저
   │
   ▼
┌─────────────────────────────────────┐
│  Cloudflare Worker (index.ts)       │
│  - Sandbox에서 OpenClaw 시작        │
│  - HTTP/WebSocket 요청 프록시       │
│  - 시크릿을 환경변수로 전달         │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│  Cloudflare Sandbox Container       │
│  ┌───────────────────────────────┐  │
│  │  OpenClaw Gateway             │  │
│  │  - 포트 18789의 Control UI    │  │
│  │  - WebSocket RPC 프로토콜     │  │
│  │  - Agent 런타임               │  │
│  └───────────────────────────────┘  │
└─────────────────────────────────────┘
```

## 프로젝트 구조

```
src/
├── index.ts          # 메인 Hono 앱, 라우트 마운팅
├── types.ts          # TypeScript 타입 정의
├── config.ts         # 상수 (포트, 타임아웃, 경로)
├── auth/             # Cloudflare Access 인증
│   ├── jwt.ts        # JWT 검증
│   ├── jwks.ts       # JWKS 페칭 및 캐싱
│   └── middleware.ts # Hono 인증 미들웨어
├── gateway/          # OpenClaw 게이트웨이 관리
│   ├── process.ts    # 프로세스 라이프사이클
│   ├── env.ts        # 환경변수 빌드
│   ├── r2.ts         # R2 버킷 마운팅
│   ├── sync.ts       # R2 백업 동기화
│   └── utils.ts      # 유틸리티
├── routes/           # API 라우트 핸들러
│   ├── api.ts        # /api/* 엔드포인트
│   ├── admin.ts      # /_admin/* 정적 파일
│   └── debug.ts      # /debug/* 엔드포인트
└── client/           # React 관리자 UI (Vite)
    ├── App.tsx
    ├── api.ts
    └── pages/
```

## 필수 요구사항

- **Workers Paid 플랜** ($5/월) - Cloudflare Sandbox 컨테이너 필요
- **Anthropic API 키** - Claude 접근용 (또는 AI Gateway Unified Billing 사용)

## 비용 예상 (24/7 실행 시)

`standard-1` 인스턴스 (1/2 vCPU, 4 GiB 메모리, 8 GB 디스크):

| 리소스 | 월간 비용 |
|--------|----------|
| 메모리 (4 GiB) | ~$26/월 |
| CPU (10% 사용률) | ~$2/월 |
| 디스크 (8 GB) | ~$1.50/월 |
| Workers Paid 플랜 | $5/월 |
| **합계** | **~$34.50/월** |

**비용 절감 팁:**
- `SANDBOX_SLEEP_AFTER=10m` 설정으로 유휴 시 컨테이너 슬립
- 하루 4시간만 실행 시 약 $10-11/월

## 주요 환경변수

### AI 제공자 (우선순위 순)

1. **Cloudflare AI Gateway (네이티브)**
   - `CLOUDFLARE_AI_GATEWAY_API_KEY`
   - `CF_AI_GATEWAY_ACCOUNT_ID`
   - `CF_AI_GATEWAY_GATEWAY_ID`
   - `CF_AI_GATEWAY_MODEL` (선택, 예: `workers-ai/@cf/meta/llama-3.3-70b-instruct-fp8-fast`)

2. **Direct Anthropic**
   - `ANTHROPIC_API_KEY`
   - `ANTHROPIC_BASE_URL` (선택)

3. **Direct OpenAI**
   - `OPENAI_API_KEY`

### 인증

- `MOLTBOT_GATEWAY_TOKEN` - Control UI 접근용 (필수)
- `CF_ACCESS_TEAM_DOMAIN` - Cloudflare Access 팀 도메인
- `CF_ACCESS_AUD` - Cloudflare Access 애플리케이션 AUD

### R2 스토리지 (영구 저장)

- `R2_ACCESS_KEY_ID`
- `R2_SECRET_ACCESS_KEY`
- `CF_ACCOUNT_ID`

### 채팅 채널 (선택)

- `TELEGRAM_BOT_TOKEN`
- `DISCORD_BOT_TOKEN`
- `SLACK_BOT_TOKEN` + `SLACK_APP_TOKEN`

### 브라우저 자동화 (CDP)

- `CDP_SECRET` - CDP 엔드포인트 인증용
- `WORKER_URL` - Worker의 공개 URL

### 개발/디버그

- `DEV_MODE=true` - CF Access 인증 + 디바이스 페어링 우회
- `DEBUG_ROUTES=true` - `/debug/*` 라우트 활성화
- `SANDBOX_SLEEP_AFTER` - 컨테이너 슬립 타임아웃 (기본: `never`)

## 인증 레이어

1. **Cloudflare Access** - 관리자 라우트 보호 (`/_admin/`, `/api/*`, `/debug/*`)
2. **Gateway Token** - Control UI 접근 필요 (`?token=` 쿼리 파라미터)
3. **Device Pairing** - 각 디바이스는 관리자 UI에서 명시적 승인 필요

## 빠른 시작

```bash
# 의존성 설치
npm install

# API 키 설정
npx wrangler secret put ANTHROPIC_API_KEY

# 게이트웨이 토큰 생성 및 설정
export MOLTBOT_GATEWAY_TOKEN=$(openssl rand -hex 32)
echo "$MOLTBOT_GATEWAY_TOKEN" | npx wrangler secret put MOLTBOT_GATEWAY_TOKEN

# 배포
npm run deploy
```

배포 후 Control UI 접근:
```
https://your-worker.workers.dev/?token=YOUR_GATEWAY_TOKEN
```

## R2 영구 저장소

R2를 설정하면 컨테이너 재시작 시에도 데이터 유지:

**동작 방식:**
- 컨테이너 시작 시: R2에서 백업 복원
- 운영 중: 5분마다 자동 백업 (cron)
- 관리자 UI에서 수동 백업 가능

**설정:**
```bash
npx wrangler secret put R2_ACCESS_KEY_ID
npx wrangler secret put R2_SECRET_ACCESS_KEY
npx wrangler secret put CF_ACCOUNT_ID
```

**중요 사항:**
- `/data/moltbot`는 R2 버킷 자체 - 삭제 시 백업 데이터 손실
- `rsync -r --no-times` 사용 (s3fs는 타임스탬프 설정 미지원)
- 백업은 `openclaw/` 프리픽스에 저장 (레거시 `clawdbot/`에서 자동 마이그레이션)

## 내장 스킬

### cloudflare-browser

CDP shim을 통한 브라우저 자동화. `CDP_SECRET`와 `WORKER_URL` 설정 필요.

**스크립트:**
- `screenshot.js` - URL 스크린샷 캡처
- `video.js` - 여러 URL에서 비디오 생성
- `cdp-client.js` - 재사용 가능한 CDP 클라이언트

**사용 예:**
```bash
node /root/clawd/skills/cloudflare-browser/scripts/screenshot.js https://example.com output.png
```

## 개발 명령어

```bash
npm test              # 테스트 실행 (vitest)
npm run test:watch    # 테스트 watch 모드
npm run build         # Worker + 클라이언트 빌드
npm run deploy        # 빌드 및 Cloudflare 배포
npm run dev           # Vite 개발 서버
npm run start         # wrangler dev (로컬 worker)
npm run typecheck     # TypeScript 체크
```

## 로컬 개발

`.dev.vars` 파일 생성:
```bash
ANTHROPIC_API_KEY=sk-ant-...
DEV_MODE=true           # CF Access 인증 + 디바이스 페어링 우회
DEBUG_ROUTES=true       # /debug/* 라우트 활성화
```

**WebSocket 제한사항:**
- `wrangler dev`는 WebSocket 프록시에 제한이 있음
- HTTP 요청은 작동하지만 WebSocket 연결은 실패할 수 있음
- 전체 기능은 Cloudflare 배포 필요

## 트러블슈팅

**게이트웨이 시작 실패:**
```bash
npx wrangler secret list  # 시크릿 확인
npx wrangler tail         # 실시간 로그
```

**첫 요청이 느림:**
- 콜드 스타트는 1-2분 소요
- 이후 요청은 빠름

**R2 마운트 안 됨:**
- 3개 시크릿 모두 설정 확인 (`R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `CF_ACCOUNT_ID`)
- R2 마운팅은 프로덕션에서만 작동 (`wrangler dev`에서는 안 됨)

**관리자 라우트 접근 거부:**
- `CF_ACCESS_TEAM_DOMAIN`과 `CF_ACCESS_AUD` 설정 확인
- Cloudflare Access 애플리케이션 올바르게 구성 확인

**디바이스가 관리자 UI에 안 보임:**
- 디바이스 목록 명령은 WebSocket 연결 오버헤드로 10-15초 소요
- 대기 후 새로고침

## 알려진 이슈

### Windows: 게이트웨이 시작 실패 (exit code 126)

Git이 CRLF 줄바꿈으로 체크아웃하면 Linux 컨테이너에서 `start-openclaw.sh` 실패. LF 줄바꿈 사용 필요:
```bash
git config --global core.autocrlf input
```

## 링크

- [OpenClaw](https://github.com/openclaw/openclaw)
- [OpenClaw Docs](https://docs.openclaw.ai/)
- [Cloudflare Sandbox Docs](https://developers.cloudflare.com/sandbox/)
- [Cloudflare Access Docs](https://developers.cloudflare.com/cloudflare-one/policies/access/)

---

**마지막 업데이트:** 2026-02-09
