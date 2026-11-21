// Shared helpers for PROJECT GATE Edge Functions.
import Stripe from "npm:stripe@17.7.0";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

// ---- Product catalog: the server's copy is the one that counts ----
// (Mirrors PORTA_PACKS / STARTER_SET / PASS in index.html. Prices in yen.)
export type Product = {
  id: string; yen: number; name: string;
  porta?: number; firstDouble?: boolean; packs?: number; item?: string; starter?: boolean; pass?: boolean;
};
export const PRODUCTS: Record<string, Product> = {
  p160:    { id: "p160",    yen: 160,   name: "ポルタ 80",    porta: 80,   firstDouble: true },
  p480:    { id: "p480",    yen: 480,   name: "ポルタ 250",   porta: 250,  firstDouble: true },
  p980:    { id: "p980",    yen: 980,   name: "ポルタ 520",   porta: 520,  firstDouble: true },
  p1500:   { id: "p1500",   yen: 1500,  name: "ポルタ 760",   porta: 760,  firstDouble: true },
  p3000:   { id: "p3000",   yen: 3000,  name: "ポルタ 1700＋限定フレーム", porta: 1700, firstDouble: true, item: "frame_portal" },
  p5000:   { id: "p5000",   yen: 5000,  name: "ポルタ 2900",  porta: 2900, firstDouble: true },
  p10000:  { id: "p10000",  yen: 10000, name: "ポルタ 6000",  porta: 6000, firstDouble: true },
  starter: { id: "starter", yen: 480,   name: "スターターセット", porta: 100, packs: 3, item: "frame_dawn", starter: true },
  pass:    { id: "pass",    yen: 600,   name: "ゲートパス（月額）", pass: true },
};
export const PASS_TRIAL_DAYS = 14;
export const AGE_CAP: Record<string, number> = { u16: 5000, u18: 10000, adult: Number.POSITIVE_INFINITY };

// ---- Clients ----
// (A placeholder keeps the function alive before the secret is set; Stripe calls then fail cleanly.)
export const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") || "sk_not_configured", {
  httpClient: Stripe.createFetchHttpClient(),
});
export const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false } },
);

// ---- CORS: only the game's own pages may call these functions ----
const ALLOWED = (Deno.env.get("ALLOWED_ORIGINS") ??
  "https://oga-0923.github.io,http://localhost:8765,http://127.0.0.1:8765").split(",").map((s) => s.trim());
export function cors(req: Request): Record<string, string> {
  const origin = req.headers.get("origin") ?? "";
  return {
    "Access-Control-Allow-Origin": ALLOWED.includes(origin) ? origin : ALLOWED[0],
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}
export function json(req: Request, body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...cors(req), "Content-Type": "application/json" } });
}

// Where Stripe sends the player back to (must be one of the game's pages).
export function returnUrl(req: Request, extra: string): string {
  const site = Deno.env.get("SITE_URL") ?? "https://oga-0923.github.io/project-gate/";
  const origin = req.headers.get("origin") ?? "";
  const base = ALLOWED.includes(origin) && !site.startsWith(origin) ? origin + "/" : site;
  return base + (base.includes("?") ? "&" : "?") + extra;
}

// The signed-in player making this request (from their Supabase session token).
export async function currentUser(req: Request) {
  const token = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token) return null;
  const { data, error } = await admin.auth.getUser(token);
  return error ? null : data.user;
}

export async function walletOf(userId: string) {
  await admin.from("wallets").upsert({ user_id: userId }, { onConflict: "user_id", ignoreDuplicates: true });
  const { data, error } = await admin.from("wallets").select("*").eq("user_id", userId).single();
  if (error) throw error;
  return data;
}

// Reuse one Stripe customer per player.
export async function customerFor(userId: string, email: string | undefined, existing: string | null) {
  if (existing) return existing;
  const c = await stripe.customers.create({ email, metadata: { user_id: userId } });
  await admin.from("wallets").update({ stripe_customer: c.id }).eq("user_id", userId);
  return c.id;
}
