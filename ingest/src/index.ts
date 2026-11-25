import { isAuthorized } from "./auth";
import { PresignError, presignPut, validatePresignInput } from "./presign";
import { replicateObject, type R2EventMessage } from "./replicate";

export type Env = {
  /** 主宛先の R2 バケット（複製の読み出し元） */
  RECORDINGS: R2Bucket;
  /** 署名に使う R2 の S3 API 情報 */
  R2_ACCOUNT_ID: string;
  R2_BUCKET: string;
  R2_ACCESS_KEY_ID: string;
  R2_SECRET_ACCESS_KEY: string;
  /** 端末トークンの SHA-256（カンマ区切り） */
  DEVICE_TOKEN_SHA256: string;
  /** 署名付きURLの有効秒数（既定 900） */
  PRESIGN_EXPIRES_SECONDS?: string;
  /** "true" で x-amz-checksum-sha256 を署名に含める */
  REQUIRE_CHECKSUM?: string;
  /** 複製先（JSON 配列）。replicate.ts の ReplicaTarget */
  REPLICA_TARGETS?: string;
  [name: string]: unknown;
};

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

export async function handleFetch(request: Request, env: Env, now?: Date): Promise<Response> {
  const url = new URL(request.url);
  if (url.pathname === "/v1/health") return json(200, { ok: true });
  if (url.pathname !== "/v1/presign") return json(404, { error: "not found" });
  if (request.method !== "POST") return json(405, { error: "POST だけを受け付けます" });
  if (!(await isAuthorized(request, env.DEVICE_TOKEN_SHA256))) return json(401, { error: "端末トークンが違います" });

  try {
    const input = validatePresignInput(await request.json().catch(() => null));
    const output = await presignPut(
      {
        endpoint: `https://${env.R2_ACCOUNT_ID}.r2.cloudflarestorage.com`,
        bucket: env.R2_BUCKET,
        region: "auto",
        accessKeyId: env.R2_ACCESS_KEY_ID,
        secretAccessKey: env.R2_SECRET_ACCESS_KEY,
      },
      input,
      {
        expiresIn: Number(env.PRESIGN_EXPIRES_SECONDS ?? "900"),
        checksum: env.REQUIRE_CHECKSUM === "true",
        now,
      },
    );
    return json(200, output);
  } catch (error) {
    if (error instanceof PresignError) return json(error.status, { error: error.message });
    throw error;
  }
}

export default {
  fetch: (request: Request, env: Env) => handleFetch(request, env),

  async queue(batch: MessageBatch<R2EventMessage>, env: Env): Promise<void> {
    for (const message of batch.messages) {
      try {
        await replicateObject(env, message.body);
        message.ack();
      } catch (error) {
        console.error("replicate failed", message.body.object?.key, String(error));
        message.retry({ delaySeconds: Math.min(600, 30 * 2 ** Math.min(5, message.attempts)) });
      }
    }
  },
} satisfies ExportedHandler<Env, R2EventMessage>;
