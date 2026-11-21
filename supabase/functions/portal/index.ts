// POST (Authorization: Bearer <session>) → { url } of Stripe's billing page,
// where players can see receipts and cancel the Gate Pass.
import { cors, currentUser, json, returnUrl, stripe, walletOf } from "../_shared/common.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  try {
    const user = await currentUser(req);
    if (!user) return json(req, { error: "login" }, 401);
    const w = await walletOf(user.id);
    if (!w.stripe_customer) return json(req, { error: "no_customer" }, 400);
    const s = await stripe.billingPortal.sessions.create({
      customer: w.stripe_customer,
      return_url: returnUrl(req, "portal=back"),
    });
    return json(req, { url: s.url });
  } catch (e) {
    console.error(e);
    return json(req, { error: "server" }, 500);
  }
});
