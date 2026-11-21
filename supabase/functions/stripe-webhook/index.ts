// Stripe → server notifications. This is the ONLY place where purchases are granted.
// Deploy with --no-verify-jwt (Stripe signs requests instead; the signature is checked below).
import Stripe from "npm:stripe@17.7.0";
import { PRODUCTS, admin, stripe } from "../_shared/common.ts";

const SECRET = Deno.env.get("STRIPE_WEBHOOK_SECRET") ?? "";
const crypto = Stripe.createSubtleCryptoProvider();

Deno.serve(async (req) => {
  const sig = req.headers.get("stripe-signature");
  const raw = await req.text();
  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(raw, sig ?? "", SECRET, undefined, crypto);
  } catch (e) {
    console.error("bad signature", e);
    return new Response("bad signature", { status: 400 });
  }

  try {
    switch (event.type) {
      // One-time purchases (Porta bundles, Starter Set)
      case "checkout.session.completed":
      case "checkout.session.async_payment_succeeded": {
        const s = event.data.object as Stripe.Checkout.Session;
        if (s.mode !== "payment" || s.payment_status !== "paid") break;
        const userId = s.metadata?.user_id, p = PRODUCTS[s.metadata?.product ?? ""];
        if (!userId || !p || p.pass) break;
        const { error } = await admin.rpc("grant_purchase", {
          p_user: userId, p_product: p.id, p_yen: s.amount_total ?? p.yen, p_ref: s.id,
          p_porta: p.porta ?? 0, p_first_double: !!p.firstDouble, p_packs: p.packs ?? 0,
          p_item: p.item ?? null, p_starter: !!p.starter,
        });
        if (error) throw error;
        break;
      }

      // Gate Pass: every paid (or free-trial) period extends the pass.
      case "invoice.paid": {
        // deno-lint-ignore no-explicit-any
        const inv = event.data.object as any;
        // Newer Stripe API versions moved the subscription id under parent.subscription_details.
        const rawSub = inv.subscription ?? inv.parent?.subscription_details?.subscription;
        const subId = typeof rawSub === "string" ? rawSub : rawSub?.id;
        if (!subId) break;
        // deno-lint-ignore no-explicit-any
        const sub = await stripe.subscriptions.retrieve(subId) as any;
        const userId = sub.metadata?.user_id;
        if (!userId) break;
        const periodEnd = sub.current_period_end ?? sub.items?.data?.[0]?.current_period_end;
        if (!periodEnd) break;
        const until = new Date(periodEnd * 1000).toISOString();
        const trial = sub.status === "trialing";
        const { error } = await admin.rpc("extend_pass", { p_user: userId, p_until: until, p_trial: trial });
        if (error) throw error;
        if ((inv.amount_paid ?? 0) > 0) {
          // Record the charge so it counts toward monthly limits and sales history (once per invoice).
          await admin.from("purchases").upsert(
            { user_id: userId, product: "pass", yen: inv.amount_paid, porta: 0, stripe_ref: inv.id },
            { onConflict: "stripe_ref", ignoreDuplicates: true },
          );
        }
        break;
      }
    }
    return new Response("ok", { status: 200 });
  } catch (e) {
    console.error(e);
    return new Response("error", { status: 500 }); // Stripe will retry
  }
});
