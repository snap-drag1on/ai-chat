# Multi-Agent AI Chat

4 ta agent, 2 ta provider, 5 ta API kalit bilan ishlaydigan AI Chat.

## Local ishga tushirish

```bash
./start.sh
```

Yoki qo'lda:

```bash
cd ai-chat
pip3 install -r requirements.txt   # bir marta
python3 api/chat.py                # yoki: ruby server.rb
```

Keyin http://localhost:3001

## Vercel ga yuklash

```bash
# 1. GitHub ga push qiling
git init
git add .
git commit -m "init"
git remote add origin <your-repo-url>
git push -u origin main

# 2. Vercel.com da import qiling
#    - Framework: Other
#    - Root: ai-chat/
#    - Build: pip install -r requirements.txt
#    - Output: api/chat.py

# 3. Environment variables (optional):
#    OPENROUTER_KEYS = sk-or-v1-xxx,sk-or-v1-yyy
#    GROQ_KEYS = gsk_xxx,gsk_yyy

# 4. Deploy
```

Yoki Vercel CLI bilan:

```bash
npm i -g vercel
vercel --prod
```

## Agents

| Agent | Provider | Model |
|-------|----------|-------|
| orchestrator | Groq | llama-3.3-70b-versatile |
| search | Groq | llama-3.3-70b-versatile |
| code | Groq | llama-3.3-70b-versatile |
| analysis | Groq | llama-3.3-70b-versatile |

OpenRouter kalitlarida credit bo'lsa, avtomatik Claude/Gemini ga o'tadi.
