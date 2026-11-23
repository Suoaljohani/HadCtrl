// push-sender — delivers queued APNs notifications (spec §18, D-36).
//
// Every in-app notification already queues one `notification_outbox` row with
// channel 'apns' in the same transaction (private.notify). This function, run
// every minute by pg_cron + pg_net (RUNBOOK §APNs), sends those rows to the
// recipient's registered devices and records the outcome:
//   - sent        APNs accepted it for at least one device
//   - cancelled   the recipient has no active device
//   - failed      after 5 attempts (exponential backoff between attempts)
// Devices APNs reports as gone (410 / BadDeviceToken) are invalidated.
//
// Lock-screen text is generic (§18/§22): no task, report or person names. The
// payload carries only the entity type and id so the app can open the record
// after the user unlocks it and the server re-checks access.
//
// Required secrets (never in the app or repository):
//   APNS_KEY_P8         contents of the AuthKey_XXXX.p8 file (token-based APNs)
//   APNS_KEY_ID         the key's id
//   APNS_TEAM_ID        Apple Developer team id
//   APNS_TOPIC          the app's bundle id
//   PUSH_SENDER_SECRET  shared secret the cron job sends in x-push-sender-secret
// Provided by the platform: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.
//
// Without the APNs secrets the function sends nothing and answers 503
// HC_APNS_NOT_CONFIGURED — it never reports a delivery that did not happen.
import { createClient } from "npm:@supabase/supabase-js@2.49.4";

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

const env = (k: string) => Deno.env.get(k) ?? "";

type Outbox = { id: number; recipient_id: string; notification_id: string | null; attempt_count: number };
type Device = { id: string; apns_token: string; environment: "development" | "production" };

// Generic, lock-screen-safe text per event family.
function alertFor(eventType: string): { title: string; body: string } {
  if (eventType.startsWith("task_")) return { title: "قيادة", body: "تحديث على إحدى مهامك" };
  if (eventType.startsWith("report_")) return { title: "قيادة", body: "تحديث على أحد التقارير" };
  if (eventType.startsWith("measurement_")) return { title: "قيادة", body: "تحديث على قراءة مؤشر" };
  if (eventType === "decision_needed" || eventType === "extension_requested") {
    return { title: "قيادة", body: "قرار بانتظارك" };
  }
  return { title: "قيادة", body: "لديك إشعار جديد" };
}

const b64url = (bytes: Uint8Array) =>
  btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

let cachedJwt: { token: string; at: number } | null = null;

// Token-based APNs auth: ES256 JWT, reused for up to 50 minutes (Apple: ≤ 60).
async function apnsJwt(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedJwt && now - cachedJwt.at < 50 * 60) return cachedJwt.token;
  const pem = env("APNS_KEY_P8").replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const enc = new TextEncoder();
  const header = b64url(enc.encode(JSON.stringify({ alg: "ES256", kid: env("APNS_KEY_ID") })));
  const claims = b64url(enc.encode(JSON.stringify({ iss: env("APNS_TEAM_ID"), iat: now })));
  const sig = new Uint8Array(
    await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, enc.encode(`${header}.${claims}`)),
  );
  cachedJwt = { token: `${header}.${claims}.${b64url(sig)}`, at: now };
  return cachedJwt.token;
}

async function send(device: Device, payload: unknown): Promise<{ ok: boolean; gone: boolean; reason?: string }> {
  const host = device.environment === "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com";
  const res = await fetch(`https://${host}/3/device/${device.apns_token}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${await apnsJwt()}`,
      "apns-topic": env("APNS_TOPIC"),
      "apns-push-type": "alert",
      "apns-priority": "10",
      "content-type": "application/json",
    },
    body: JSON.stringify(payload),
  });
  if (res.status === 200) return { ok: true, gone: false };
  let reason = `http_${res.status}`;
  try { reason = (await res.json()).reason ?? reason; } catch { /* empty body */ }
  const gone = res.status === 410 || reason === "BadDeviceToken" || reason === "Unregistered";
  return { ok: false, gone, reason };
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json(405, { code: "HC_METHOD_NOT_ALLOWED" });
  const secret = env("PUSH_SENDER_SECRET");
  if (!secret || req.headers.get("x-push-sender-secret") !== secret) return json(401, { code: "HC_AUTH_REQUIRED" });
  if (!env("APNS_KEY_P8") || !env("APNS_KEY_ID") || !env("APNS_TEAM_ID") || !env("APNS_TOPIC")) {
    return json(503, { code: "HC_APNS_NOT_CONFIGURED" });
  }

  const admin = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: due, error } = await admin.from("notification_outbox")
    .select("id,recipient_id,notification_id,attempt_count")
    .eq("channel", "apns").eq("status", "pending").lte("next_attempt_at", new Date().toISOString())
    .order("id").limit(100);
  if (error) return json(500, { code: "HC_SERVER_ERROR" });

  const summary = { sent: 0, cancelled: 0, retried: 0, failed: 0 };
  for (const row of (due ?? []) as Outbox[]) {
    const [{ data: devices }, { data: note }] = await Promise.all([
      admin.from("device_registrations").select("id,apns_token,environment")
        .eq("user_id", row.recipient_id).is("invalidated_at", null),
      row.notification_id
        ? admin.from("notifications").select("event_type,entity_type,entity_id").eq("id", row.notification_id).maybeSingle()
        : Promise.resolve({ data: null }),
    ]);
    if (!devices || devices.length === 0 || !note) {
      await admin.from("notification_outbox").update({ status: "cancelled", last_error_code: "no_device" }).eq("id", row.id);
      summary.cancelled++;
      continue;
    }
    const payload = {
      aps: { alert: alertFor(note.event_type), sound: "default", "thread-id": note.entity_type },
      hc: { entity_type: note.entity_type, entity_id: note.entity_id },
    };
    let delivered = false;
    let lastReason = "";
    for (const d of devices as Device[]) {
      try {
        const r = await send(d, payload);
        if (r.ok) delivered = true;
        if (r.gone) {
          await admin.from("device_registrations").update({ invalidated_at: new Date().toISOString() }).eq("id", d.id);
        }
        if (!r.ok) lastReason = r.reason ?? "unknown";
      } catch (_) {
        lastReason = "network";
      }
    }
    if (delivered) {
      await admin.from("notification_outbox").update({ status: "sent", last_error_code: null }).eq("id", row.id);
      summary.sent++;
    } else {
      const attempts = row.attempt_count + 1;
      const done = attempts >= 5;
      const next = new Date(Date.now() + 60_000 * 2 ** attempts).toISOString();
      await admin.from("notification_outbox").update({
        status: done ? "failed" : "pending", attempt_count: attempts, next_attempt_at: next,
        last_error_code: lastReason.slice(0, 60),
      }).eq("id", row.id);
      if (done) summary.failed++; else summary.retried++;
    }
  }
  return json(200, summary);
});
