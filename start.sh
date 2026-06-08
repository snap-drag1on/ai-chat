#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
PORT=${PORT:-3001}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Multi-Agent AI Chat"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

kill $(lsof -ti:$PORT) 2>/dev/null

# Prefer Python, fallback to Ruby
if command -v python3 &>/dev/null && python3 -c "import flask" 2>/dev/null; then
  echo "  Backend: Python (Flask)"
  cd "$DIR" && python3 api/chat.py &
elif command -v ruby &>/dev/null; then
  echo "  Backend: Ruby (WEBrick)"
  ruby "$DIR/server.rb" &
else
  echo "  ERROR: Python or Ruby required"
  exit 1
fi

sleep 3
open "http://localhost:$PORT" 2>/dev/null
echo "  URL: http://localhost:$PORT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
wait
