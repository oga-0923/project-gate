# PROJECT GATE 課金（Stripe）セットアップ手順

Web版で「ログイン・クラウド保存・Stripe決済」を動かすための手順です。
**まずはテストモード（本物のお金は動かない）** で全部つなげて動作確認し、本番は会社の登記・Stripeの審査が済んでから切り替えます。

```
プレイヤー ─ ログイン/セーブ ─▶ Supabase（データベース）
    │                              ▲
    │ 購入ボタン                    │ 支払い完了の通知（webhook）で
    ▼                              │ ポルタ・パックを付与
 checkout 関数 ─▶ Stripe のお支払いページ ─┘
```

- 有償ポルタ・購入履歴・年齢区分・ゲートパスの期限は **サーバー側だけ** で管理（改ざんできない）
- ポルタやパックは **Stripe から「支払い完了」の通知が届いてから** 付与
- カード番号は Stripe が直接扱い、こちらでは保存しない

---

## あなたにやってもらうこと（アカウント作成・秘密のキーの入力）

### 1. Supabase のプロジェクトを作る（無料）
1. https://supabase.com で「Start your project」→ GitHub アカウントでサインアップ
2. 「New project」
   - Name：`project-gate`
   - Database Password：強いパスワードを作り、**パスワード管理アプリなどに保存**（あとで1回使います）
   - Region：**Northeast Asia (Tokyo)**
3. 作成後、左下の「Project Settings → API」で次の2つを確認
   - **Project URL**（`https://xxxx.supabase.co`）
   - **anon public** キー（公開してよいキー）
   → この2つは Claude に伝えてOKです（ゲームに埋め込む公開用の値です）
   → **service_role キーは絶対に伝えない・公開しない**でください

### 2. Supabase の「ログイン」設定
1. 「Authentication → URL Configuration」
   - Site URL：`https://oga-0923.github.io/project-gate/`
   - Redirect URLs に追加：`https://oga-0923.github.io/project-gate/` と `http://localhost:8765/`
2. メールでのログインは最初から使えます（Authentication → Providers → Email が ON）
3. Google ログイン（任意・あとでもOK）
   1. https://console.cloud.google.com →「APIとサービス → 認証情報 → OAuth クライアント ID を作成」（種類：ウェブアプリケーション）
   2. 「承認済みのリダイレクト URI」に `https://xxxx.supabase.co/auth/v1/callback`（xxxx は自分のプロジェクト）
   3. 表示されたクライアントIDとシークレットを、Supabase の「Authentication → Providers → Google」に入力して ON

### 3. Stripe アカウントを作る（テストモード）
1. https://dashboard.stripe.com/register でアカウント作成（テストモードは審査なしですぐ使えます）
2. 右上が **「テストモード」** になっていることを確認
3. 「開発者 → API キー」で **シークレットキー（`sk_test_…`）** を確認
   → **このキーは Claude に送らないでください。** 下のコマンドで、ご自身でターミナルに貼り付けます
4. 「設定 → Billing → カスタマーポータル」を開き、テストモードで一度「保存」（解約ボタン用）

---

## ターミナルで実行するコマンド（Claude が案内します）

`SB=~/.local/supabase-cli/v3.2.0/supabase` として：

```bash
cd ~/Downloads/project-gate
$SB login                                   # ブラウザが開くので Supabase にログイン
$SB link --project-ref xxxx                 # xxxx = Project URL の https:// と .supabase.co の間。DBパスワードを聞かれます
$SB db push                                 # データベースの表と関数を作成
$SB secrets set STRIPE_SECRET_KEY=sk_test_ここに自分のキー
$SB functions deploy checkout portal stripe-webhook --use-api
```

### 4. Stripe に「支払い完了の通知先」を登録
1. Stripe「開発者 → Webhook → エンドポイントを追加」
   - URL：`https://xxxx.supabase.co/functions/v1/stripe-webhook`
   - イベント：`checkout.session.completed`、`checkout.session.async_payment_succeeded`、`invoice.paid`
2. 作成後に表示される **署名シークレット（`whsec_…`）** を、ターミナルで：
```bash
$SB secrets set STRIPE_WEBHOOK_SECRET=whsec_ここに自分の値
```

### 5. ゲームに接続（Claude が行います）
`index.html` の `CLOUD.url` と `CLOUD.anon` に手順1の値を入れて公開します。

---

## テスト購入のしかた
- カード番号 `4242 4242 4242 4242`、有効期限は未来の日付、CVC は任意の3桁
- 購入後、ゲームに戻るとポルタ・パックが増えます。Stripe の「支払い」と Supabase の `purchases` 表にも記録が残ります

## 本番に切り替えるとき（会社の登記後）
1. Stripe の本番申請（会社情報・口座・特定商取引法の表記URL：`https://oga-0923.github.io/project-gate/legal/tokushoho.html`）
2. 本番用のキー（`sk_live_…`）と本番の Webhook（`whsec_…`）で `secrets set` をやり直す
3. `index.html` の `CLOUD.testMode` を `false` にして公開
4. 法的表示の所在地・連絡先を確定（会社用メールアドレス推奨）。専門家に一度確認してもらうと安心です
5. 有償ポルタの未使用残高が基準日（3月末・9月末）に1,000万円を超えたら、資金決済法の届出が必要です（残高は `porta_ledger` / `wallets` 表で確認できます）
