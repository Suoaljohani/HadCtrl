// create-employee — server-side account creation for the in-app admin (D-25).
//
// Flow (the admin key never leaves this function):
//  1. Verify the caller's access token with Supabase Auth.
//  2. Call prepare_employee AS THE CALLER (their token): all authorization,
//     escalation and validation rules run in SQL (tested in 70_admin).
//  3. With the secret key: reuse the Auth user for that email if it exists,
//     otherwise create it with a random temporary password (email confirmed).
//  4. complete_employee (service role only) attaches profile + memberships
//     atomically and marks must_change_password for new accounts.
//  5. Return the temporary password ONCE. It is never stored or logged.
//
// Deployed with verify_jwt = false because the platform check only understands
// legacy JWT keys; this function verifies the caller itself (step 1).
import { createClient } from "npm:@supabase/supabase-js@2.49.4";

type Body = {
  organization_id: string;
  email: string;
  display_name: string;
  job_title?: string | null;
  org_role?: string | null;
  department_id?: string | null;
  department_role?: string | null;
  is_primary?: boolean;
  request_id: string;
};

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

// HC_* codes are the only error vocabulary the app understands (§27).
const fail = (status: number, code: string, details: Record<string, unknown> = {}, correlationId?: string) =>
  json(status, { code, details, correlation_id: correlationId });

const statusFor: Record<string, number> = {
  HC_AUTH_REQUIRED: 401, HC_MEMBERSHIP_INACTIVE: 403, HC_FORBIDDEN: 403, HC_NOT_FOUND: 404,
  HC_VALIDATION_FAILED: 422, HC_IDEMPOTENCY_MISMATCH: 409, HC_VERSION_CONFLICT: 409,
};

// 14 characters from an alphabet without look-alikes (no 0/O, 1/l/I), with
// guaranteed upper, lower, digit and symbol. crypto.getRandomValues only.
function temporaryPassword(): string {
  const sets = ["ABCDEFGHJKLMNPQRSTUVWXYZ", "abcdefghijkmnopqrstuvwxyz", "23456789", "!@#$%*?-+"];
  const all = sets.join("");
  const pick = (s: string) => {
    const buf = new Uint32Array(1);
    // Rejection sampling avoids modulo bias.
    const limit = Math.floor(0xffffffff / s.length) * s.length;
    do { crypto.getRandomValues(buf); } while (buf[0] >= limit);
    return s[buf[0] % s.length];
  };
  const chars = [...sets.map(pick), ...Array.from({ length: 10 }, () => pick(all))];
  for (let i = chars.length - 1; i > 0; i--) {            // Fisher–Yates shuffle
    const j = Number(BigInt(crypto.getRandomValues(new Uint32Array(1))[0]) % BigInt(i + 1));
    [chars[i], chars[j]] = [chars[j], chars[i]];
  }
  return chars.join("");
}

Deno.serve(async (req: Request) => {
  const correlationId = crypto.randomUUID();
  if (req.method !== "POST") return fail(405, "HC_VALIDATION_FAILED", { method: "POST only" }, correlationId);

  const url = Deno.env.get("SUPABASE_URL")!;
  const publishable = JSON.parse(Deno.env.get("SUPABASE_PUBLISHABLE_KEYS") ?? "{}")["default"];
  const secret = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}")["default"];
  if (!url || !publishable || !secret) return fail(500, "HC_SERVER_ERROR", { reason: "keys_unavailable" }, correlationId);

  // 1. Caller identity, verified by the Auth server.
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token || token === publishable) return fail(401, "HC_AUTH_REQUIRED", {}, correlationId);
  const userClient = createClient(url, publishable, {
    global: { headers: { Authorization: `Bearer ${token}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: who, error: whoError } = await userClient.auth.getUser(token);
  if (whoError || !who?.user) return fail(401, "HC_AUTH_REQUIRED", {}, correlationId);

  let body: Body;
  try { body = await req.json(); } catch { return fail(422, "HC_VALIDATION_FAILED", { body: "invalid_json" }, correlationId); }

  // 2. Authorization + validation in SQL, as the caller.
  const { data: prepared, error: prepError } = await userClient.rpc("prepare_employee", {
    p_organization_id: body.organization_id,
    p_email: body.email,
    p_display_name: body.display_name,
    p_request_id: body.request_id,
    p_job_title: body.job_title ?? null,
    p_org_role: body.org_role ?? "member",
    p_department_id: body.department_id ?? null,
    p_department_role: body.department_role ?? null,
    p_is_primary: body.is_primary ?? false,
  });
  if (prepError) {
    const code = statusFor[prepError.message] ? prepError.message : "HC_SERVER_ERROR";
    let details: unknown = {};
    try { details = prepError.details ? JSON.parse(prepError.details) : {}; } catch { /* keep empty */ }
    return fail(statusFor[code] ?? 500, code, details as Record<string, unknown>, correlationId);
  }
  const provisioningId: string = prepared.provisioning_id;

  const admin = createClient(url, secret, { auth: { persistSession: false, autoRefreshToken: false } });

  // A replayed request that already completed: never re-issue a password.
  const { data: status } = await admin.rpc("provisioning_status", { p_provisioning_id: provisioningId });
  if (status?.status === "completed") {
    return json(200, { user_id: status.user_id, account_created: false, temporary_password: null, replayed: true });
  }
  if (!status || status.requested_by !== who.user.id) {
    return fail(403, "HC_FORBIDDEN", {}, correlationId);
  }

  // 3. Reuse or create the Auth user.
  let userId: string | null = null;
  let created = false;
  let password: string | null = null;
  const { data: existing } = await admin.rpc("find_auth_user_id", { p_email: status.email });
  if (existing) {
    userId = existing as string;
  } else {
    password = temporaryPassword();
    const { data: createdUser, error: createError } = await admin.auth.admin.createUser({
      email: status.email, password, email_confirm: true,
    });
    if (createError || !createdUser?.user) {
      await admin.rpc("fail_provisioning", { p_provisioning_id: provisioningId, p_code: "auth_create_failed" });
      console.error(JSON.stringify({ correlationId, step: "createUser", code: createError?.code ?? "unknown" }));
      return fail(502, "HC_SERVER_ERROR", { step: "create_user" }, correlationId);
    }
    userId = createdUser.user.id;
    created = true;
  }

  // 4. Attach profile + memberships atomically.
  const { error: completeError } = await admin.rpc("complete_employee", {
    p_provisioning_id: provisioningId, p_user_id: userId, p_account_created: created,
  });
  if (completeError) {
    await admin.rpc("fail_provisioning", { p_provisioning_id: provisioningId, p_code: "complete_failed" });
    console.error(JSON.stringify({ correlationId, step: "complete_employee", code: completeError.code ?? "unknown" }));
    const code = statusFor[completeError.message] ? completeError.message : "HC_SERVER_ERROR";
    return fail(statusFor[code] ?? 500, code, {}, correlationId);
  }

  // 5. Shown once to the admin; not stored, not logged.
  return json(200, { user_id: userId, account_created: created, temporary_password: password, replayed: false });
});
