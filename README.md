# Multi-Agent AI Chat

4 ta agent bilan ishlaydigan AI chat — har bir agent alohida vazifa bajaradi, natijalarni sintez qilib foydalanuvchiga yagona javob qaytaradi.

## Nima qiladi?

Foydalanuvchi bironta savol yozadi → backend 4 agentni ishga tushuradi:

```
Foydalanuvchi → Orchestrator → Search (parallel) + Code (parallel) → Analysis → Javob
```

1. **Orchestrator** — savolni tahlil qiladi, qaysi agent nimani bajarishi kerakligini rejalashtiradi
2. **Search** — ma'lumot qidirish, tadqiqot, faktlarni topish
3. **Code** — kod yozish, misollar tayyorlash
4. **Analysis** — barcha agent natijalarini birlashtirib, yakuniy javobni stream qilib yozadi

## Arxitektura

```
frontend (index.html)
    ↓ POST /api/chat  (SSE)
backend (api/chat.py)
    ↓ parallel HTTP
Groq API (llama-3.3-70b-versatile)
```

- Frontend: bitta HTML fayl (CSS + JS ichida) — dark theme, pill composer, streaming, thinking steps
- Backend: Python Flask yoki Ruby WEBrick — multi-agent orchestrator, SSE streaming, key rotation, provider fallback
- API: OpenAI-compatible chat completions endpoint

## Agent Pipeline

Har bir agent `llama-3.3-70b-versatile` modeli bilan ishlaydi (Groq bepul). Agar OpenRouter kalitlarida credit bo'lsa, avtomatik Claude/Gemini ga o'tadi.

### Provider Fallback

| Provider | Model | Holati |
|----------|-------|--------|
| Groq (primary) | llama-3.3-70b-versatile | Bepul, ishlaydi |
| OpenRouter (fallback) | claude-3.5 / gemini-2.0 | Credit kerak |

### Key Rotation

5 ta API kalit aylanma tartibda ishlatiladi (round-robin). Agar bitta kalit limitga yetsa, keyingisiga o'tadi.

## Fayllar

| Fayl | Vazifasi |
|------|----------|
| `index.html` | Frontend (dark theme, streaming, thinking panel, source cards) |
| `api/chat.py` | Python Flask backend (Vercel serverless) |
| `server.rb` | Ruby WEBrick backend (local development) |
| `vercel.json` | Vercel config (60s timeout, 512MB) |
| `requirements.txt` | Python dependencies (flask, requests) |
| `start.sh` | Local ishga tushirish skripti |
| `.env.example` | Talab qilinadigan env var'lar |
| `.env` | API kalitlar (commit qilinmaydi) |
| `.gitignore` | .env ni ignore qiladi |

## O'rnatish

### Local

```bash
pip3 install -r requirements.txt
python3 api/chat.py
# → http://localhost:3001
```

Yoki Ruby bilan:
```bash
ruby server.rb
# → http://localhost:3001
```

### Vercel

```bash
# GitHub repo yaratib, push qiling
git init && git add . && git commit -m "init"
git remote add origin https://github.com/USER/ai-chat.git
git push -u origin main

# Vercel.com → Add New → Import repo
# Framework: Other (vercel.json da belgilangan)
# Env vars:
#   GROQ_KEYS=gsk_xxx,gsk_yyy
```

## Environment Variables

| Variable | Format | Kerak |
|----------|--------|-------|
| `GROQ_KEYS` | `gsk_xxx,gsk_yyy` | Ha (2 ta) |
| `OPENROUTER_KEYS` | `sk-or-v1-xxx,sk-or-v1-yyy,sk-or-v1-zzz` | Yo'q (optional, credit kerak) |

## SSE Events

Backend frontendga quyidagi event'larni yuboradi:

| Event | Ma'nosi |
|-------|---------|
| `thinking` | Agent ishlayapti (step, label, total) |
| `agent_result` | Agent natijasi (JSON) |
| `sources` | Manbalar (title, domain) |
| `agent_stream_start` | Analysis agent streaming boshladi |
| `token` | Yakuniy javob tokeni |
| `error` | Xatolik |
| `done` | Tugadi |

## Send Button States

3 xil holat:
- 🎤 Mikrofon (bo'sh input)
- ➡️ Yuborish (matn bor)
- ⏹ Stop (ishlayapti)
