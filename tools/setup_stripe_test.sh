#!/bin/zsh
# PROJECT GATE: connect Stripe (test mode) to Supabase in one go.
# - Asks for your Stripe secret key without showing it on screen
# - Registers it as a Supabase secret (it never goes into the game or GitHub)
# - Creates the webhook (payment-complete notifications) and stores its signing secret
# - Turns on Stripe's customer portal (receipts / cancel the Gate Pass)
set -e
SB=~/.local/supabase-cli/v3.2.0/supabase
REF=lvalxfgbazyoavoswtep
HOOK_URL="https://$REF.supabase.co/functions/v1/stripe-webhook"
cd ~/Downloads/project-gate

api() { curl -sS -u "$KEY:" "$@"; }

# The key is read straight from the clipboard (no pasting needed) and never printed.
# On a mismatch only the first 8 characters and the length are shown, to help find the problem.
while true; do
  echo ""
  echo "① Stripe の画面で、シークレットキー（sk_test_…）の 📋 を押してコピー"
  echo "② ここ（ターミナル）をクリックして、Enter キーだけを押してください"
  echo "   （やめるときは control + C）"
  read -rs "DUMMY?> "
  echo ""
  KEY=$(pbpaste | tr -d '[:space:]')
  case "$KEY" in
    sk_test_*|rk_test_*)
      echo "1/4 キーを確認しています…"
      if api https://api.stripe.com/v1/balance | grep -q '"object": "balance"'; then break; fi
      echo "   → sk_test_ で始まるキーでしたが、Stripe に使えないと言われました（${#KEY}文字）。"
      echo "     キーの一部しかコピーできていない可能性があります。もう一度コピーしてください。" ;;
    sk_live_*|rk_live_*)
      echo "   → 本番用のキー（sk_live_）でした。今はテスト用（sk_test_）をコピーしてください。" ;;
    "")
      echo "   → クリップボードが空でした。Stripe の 📋 を押せていないようです。" ;;
    *)
      echo "   → クリップボードの中身はキーではありませんでした（先頭：「${KEY[1,8]}…」、${#KEY}文字）。"
      echo "     Stripe の 📋 を押してから、もう一度 Enter を押してください。" ;;
  esac
done

echo "2/4 Supabase にキーを登録しています…"
$SB secrets set --remote=$REF --yes STRIPE_SECRET_KEY="$KEY" >/dev/null

echo "3/4 支払い完了の通知先（Webhook）を作成しています…"
for id in $(api "https://api.stripe.com/v1/webhook_endpoints?limit=100" | tr -d '\n' | awk '{gsub(/"id": *"we_/,"\n&"); print}' | grep -F "\"$HOOK_URL\"" | grep -o 'we_[A-Za-z0-9]*' | sort -u); do
  api -X DELETE "https://api.stripe.com/v1/webhook_endpoints/$id" >/dev/null   # remove an old one so the secret matches
done
RESP=$(api https://api.stripe.com/v1/webhook_endpoints \
  -d url="$HOOK_URL" \
  -d "enabled_events[]=checkout.session.completed" \
  -d "enabled_events[]=checkout.session.async_payment_succeeded" \
  -d "enabled_events[]=invoice.paid" \
  -d description="PROJECT GATE")
WHSEC=$(echo "$RESP" | grep -o 'whsec_[A-Za-z0-9]*' | head -1)
[ -n "$WHSEC" ] || { echo "Webhook を作成できませんでした。"; echo "$RESP" | grep '"message"'; exit 1; }
$SB secrets set --remote=$REF --yes STRIPE_WEBHOOK_SECRET="$WHSEC" >/dev/null

echo "4/4 解約・領収書の画面（カスタマーポータル）を有効にしています…"
api https://api.stripe.com/v1/billing_portal/configurations \
  -d "business_profile[headline]=PROJECT GATE" \
  -d "features[invoice_history][enabled]=true" \
  -d "features[payment_method_update][enabled]=true" \
  -d "features[subscription_cancel][enabled]=true" \
  -d "features[subscription_cancel][mode]=at_period_end" \
  -d "default_return_url=https://oga-0923.github.io/project-gate/" >/dev/null

unset KEY WHSEC RESP
echo ""
echo "✅ 完了しました。Stripe（テストモード）とサーバーがつながりました。"
