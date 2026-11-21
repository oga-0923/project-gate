// POST { product: "p480" | "starter" | "pass", trial?: boolean }  (Authorization: Bearer <session>)
// → { url } of a Stripe Checkout page. All prices and limits are decided here, not in the game.
import { AGE_CAP, PASS_TRIAL_DAYS, PRODUCTS, admin, cors, currentUser, customerFor, json, returnUrl, stripe, walletOf } from "../_shared/common.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return json(req, { error: "method" }, 405);
  // Sales switch: no checkout pages are created unless the secret PAYMENTS_ENABLED is "true".
  if (Deno.env.get("PAYMENTS_ENABLED") !== "true") return json(req, { error: "disabled" }, 403);
  try {
    const user = await currentUser(req);
    if (!user) return json(req, { error: "login" }, 401);

    const body = await req.json().catch(() => ({}));
    const p = PRODUCTS[String(body.product ?? "")];
    if (!p) return json(req, { error: "product" }, 400);

    const w = await walletOf(user.id);
    if (!w.age_group) return json(req, { error: "age" }, 400);

    // Monthly limit for under-18 players (counts what was actually paid this month, Japan time).
    const { data: spent } = await admin.rpc("month_spent", { uid: user.id });
    const cap = AGE_CAP[w.age_group];
    const wantsTrial = p.pass && body.trial === true && !w.trial_used;
    const chargeNow = wantsTrial ? 0 : p.yen;
    if ((spent ?? 0) + chargeNow > cap) return json(req, { error: "cap", cap, spent }, 400);

    if (p.starter && w.starter_bought) return json(req, { error: "starter_done" }, 400);
    if (p.pass && w.pass_until && new Date(w.pass_until).getTime() > Date.now() + 3 * 864e5) {
      return json(req, { error: "pass_active" }, 400);
    }

    const customer = await customerFor(user.id, user.email ?? undefined, w.stripe_customer);
    const meta = { user_id: user.id, product: p.id };
    const common = {
      customer,
      client_reference_id: user.id,
      locale: "auto" as const,
      success_url: returnUrl(req, "checkout=success"),
      cancel_url: returnUrl(req, "checkout=cancel"),
      metadata: meta,
    };

    const session = p.pass
      ? await stripe.checkout.sessions.create({
          ...common,
          mode: "subscription",
          line_items: [{ quantity: 1, price_data: {
            currency: "jpy", unit_amount: p.yen, recurring: { interval: "month" },
            product_data: { name: p.name },
          } }],
          subscription_data: { metadata: meta, ...(wantsTrial ? { trial_period_days: PASS_TRIAL_DAYS } : {}) },
        })
      : await stripe.checkout.sessions.create({
          ...common,
          mode: "payment",
          line_items: [{ quantity: 1, price_data: {
            currency: "jpy", unit_amount: p.yen, product_data: { name: p.name },
          } }],
          payment_intent_data: { metadata: meta },
        });

    return json(req, { url: session.url });
  } catch (e) {
    console.error(e);
    return json(req, { error: "server" }, 500);
  }
});
