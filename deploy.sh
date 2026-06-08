#!/bin/bash
set -e

echo "╔════════════════════════════════════╗"
echo "║  AI Chat - Auto Deploy             ║"
echo "╚════════════════════════════════════╝"

# Check tools
for cmd in git curl zip; do
  command -v $cmd >/dev/null 2>&1 || { echo "Xato: $cmd topilmadi"; exit 1; }
done

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

# GitHub token
echo ""
echo "GitHub Token kiriting:"
echo "(https://github.com/settings/tokens → generate new → classic,"
echo "repo, workflow, write:packages) ni belgilang)"
read -p "Token: " GH_TOKEN

USERNAME=$(curl -s -H "Authorization: token $GH_TOKEN" https://api.github.com/user | grep -o '"login": "[^"]*"' | cut -d'"' -f4)
echo ""

if [ -z "$USERNAME" ]; then
  echo "Xato: Token yaroqsiz!"
  exit 1
fi

echo "GitHub user: $USERNAME"

# Create repo
echo "GitHub repo yaratilmoqda..."
curl -s -X POST -H "Authorization: token $GH_TOKEN" \
  -H "Accept: application/vnd.github.v3+json" \
  https://api.github.com/user/repos \
  -d '{"name":"ai-chat","private":false}' > /dev/null

git remote remove origin 2>/dev/null || true
git remote add origin "https://$GH_TOKEN@github.com/$USERNAME/ai-chat.git"
git push -u origin main 2>&1 | tail -3

echo ""
echo "========================================"
echo "✅ GitHub: https://github.com/$USERNAME/ai-chat"
echo ""
echo "Endi Vercel.com ga o'ting:"
echo "1. https://vercel.com → Add New Project"
echo "2. Import $USERNAME/ai-chat"
echo "3. Deploy (sozlamalarni o'zgartirmang)"
echo "4. Settings → Environment Variables:"
echo "   OPENROUTER_KEYS = 3 ta kalitni vergul bilan"
echo "   GROQ_KEYS = 2 ta kalitni vergul bilan"
echo "========================================"

# Try vercel deploy if available
if command -v npx &>/dev/null; then
  echo ""
  echo "Vercel CLI topildi. Deploy qilaymi? (y/n)"
  read -p "> " ANS
  if [ "$ANS" = "y" ]; then
    echo "Vercel token kiriting (https://vercel.com/account/tokens):"
    read -s -p "Token: " VERCEL_TOKEN
    echo ""
    VERCEL_ORG_ID=$(curl -s -H "Authorization: Bearer $VERCEL_TOKEN" https://api.vercel.com/v2/user | grep -o '"uid":"[^"]*"' | head -1 | cut -d'"' -f4)
    curl -s -X POST -H "Authorization: Bearer $VERCEL_TOKEN" \
      -H "Content-Type: application/json" \
      "https://api.vercel.com/v13/deployments" \
      -d "{
        \"name\":\"ai-chat\",
        \"projectSettings\":{
          \"framework\":null,
          \"buildCommand\":null,
          \"outputDirectory\":null
        },
        \"files\":[]
      }" > /dev/null
    echo "✅ Vercel deploy boshlangan. Dashboarddan kuzating."
  fi
fi

echo ""
echo "Tayyor! 🎉"
