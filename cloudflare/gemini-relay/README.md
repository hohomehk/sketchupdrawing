# hohome-gemini-proxy

**Deployed:** `https://hohome-gemini-proxy.hohome-tim.workers.dev` (since 2026-05-02)
**Account:** Timothy / `945eb571b27f72d3ad419c2468313f6f`
**Secrets stored locally:** `~/.openclaw/marketing/.env` → `GEMINI_API_KEY`, `GEMINI_RELAY_SECRET`

Cloudflare Worker 將 Gemini API（REST + Live WebSocket）relay 比 HK/CN 後面 firewall 嘅 SketchUp plugin user。

## 架構

```
SU Plugin (HK/CN)
    │
    │  wss://hohome-gemini-relay.<acct>.workers.dev/ws/live?auth=...&model=...
    │  https://hohome-gemini-relay.<acct>.workers.dev/v1beta/models/...:generateContent
    ▼
Cloudflare Edge (CF Workers)
    │
    │  注入 ?key=GEMINI_API_KEY，剝走 X-Relay-Secret
    ▼
generativelanguage.googleapis.com
```

兩個 secret 留喺 CF Workers env vars，**唔會** bundle 入 .rbz：

| Secret | 用途 |
|---|---|
| `GEMINI_API_KEY` | Worker 自己對 Google 用，client 永遠睇唔到 |
| `RELAY_SECRET` | Plugin 同 Worker 共享，防止 Worker URL 公開後比人盜用 |

`RELAY_SECRET` 可以 bundle 入 .rbz（內部 plugin，可接受），洩漏後重生一個 redeploy 即可，唔影響 Gemini key。

## Routes

| Route | 用途 |
|---|---|
| `GET /healthz` | 健康檢查 |
| `ANY /v1beta/<...>` | REST proxy（`generateContent`、`embedContent` 等）。Auth 用 header `X-Relay-Secret` |
| `GET /ws/live` | Live API WebSocket relay。Auth 用 query `?auth=...`（WS upgrade 唔可以 set custom header） |

## Deploy

```bash
cd cloudflare/gemini-relay
npm install

# 一次性登入
npx wrangler login

# 設 secrets（會 prompt 輸入值，唔會留喺 git 入面）
npx wrangler secret put GEMINI_API_KEY
npx wrangler secret put RELAY_SECRET    # 自己 random 一個，例如 openssl rand -hex 32

# Deploy
npx wrangler deploy
```

完成後會見到 URL，類似：
```
https://hohome-gemini-relay.<your-subdomain>.workers.dev
```

驗證：
```bash
curl https://hohome-gemini-relay.<your-subdomain>.workers.dev/healthz
# → ok

curl -X POST \
  -H "X-Relay-Secret: $RELAY_SECRET" \
  -H "Content-Type: application/json" \
  -d '{"contents":[{"parts":[{"text":"say hi"}]}]}' \
  https://hohome-gemini-relay.<your-subdomain>.workers.dev/v1beta/models/gemini-2.0-flash-exp:generateContent
```

## Plugin 點接

喺 `su_gpt_render.rb` 入面新增 constant：

```ruby
GEMINI_RELAY_URL    = "https://hohome-gemini-relay.<your-subdomain>.workers.dev"
GEMINI_RELAY_SECRET = "<the-RELAY_SECRET-you-set-above>"
```

REST call：
```ruby
uri = URI("#{GEMINI_RELAY_URL}/v1beta/models/gemini-2.5-flash:generateContent")
req = Net::HTTP::Post.new(uri)
req["X-Relay-Secret"] = GEMINI_RELAY_SECRET
req["Content-Type"]   = "application/json"
req.body = { contents: [...] }.to_json
```

Live WebSocket（pure-Ruby ws client）：
```ruby
ws_url = "wss://hohome-gemini-relay.<your-subdomain>.workers.dev/ws/live" \
         "?auth=#{GEMINI_RELAY_SECRET}&model=gemini-2.0-flash-exp"
# 連上之後第一個 frame send setup message，跟住 streamingly send
# realtime input（screen frames as JPEG base64 + audio if needed）
```

## 費用估算

Free tier：
- 100,000 requests/day
- 10ms CPU/req（WS 連接 duration **唔計** CPU，只計 message 處理時間）
- 1MB script size

對單一公司內部 plugin（< 50 user）綽綽有餘。如果要擴展，Workers Paid US$5/month 提供 10M req/month。

Live API 本身嘅 Google 費用見 plugin 內部 cost meter — relay Worker 唔會額外加錢。

## 將來想加

- [ ] Per-user rate limit（用 KV 或 Durable Object）
- [ ] Audit log（每個 session 寫入 R2）
- [ ] Multiple `RELAY_SECRET` 支援（per-user secret，方便 revoke 單一 user）
- [ ] 健康檢查：嘗試接一次 upstream WS 確認 Google 端可達
