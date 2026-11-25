import { describe, expect, it } from "vitest";
import { allowedHashes, isAuthorized, sha256Hex } from "../src/auth";
import { handleFetch, type Env } from "../src/index";
import { parseObjectKey } from "../src/keys";
import { hexToBase64, presignPut, validatePresignInput } from "../src/presign";
import { replicateObject, shouldReplicate } from "../src/replicate";

const SHA = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
const KEY = "recordings/20261125T091900Z-3f9a2c1b/segments/000000.m4a";

async function env(overrides: Partial<Env> = {}): Promise<Env> {
  return {
    RECORDINGS: {} as R2Bucket,
    R2_ACCOUNT_ID: "acc123",
    R2_BUCKET: "voice-recordings",
    R2_ACCESS_KEY_ID: "AKIDEXAMPLE",
    R2_SECRET_ACCESS_KEY: "secret",
    DEVICE_TOKEN_SHA256: `${await sha256Hex("device-token")},${"0".repeat(64)}`,
    ...overrides,
  };
}

function presignRequest(body: unknown, token = "device-token"): Request {
  return new Request("https://ingest.example.dev/v1/presign", {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

describe("keys", () => {
  it("iOS と同じ形のキーだけを受け付ける", () => {
    expect(parseObjectKey(KEY)).toEqual({ recordingId: "20261125T091900Z-3f9a2c1b", kind: "segment" });
    expect(parseObjectKey("recordings/20261125T091900Z-3f9a2c1b/manifest.json")?.kind).toBe("manifest");
    expect(parseObjectKey("recordings/../secret")).toBeNull();
    expect(parseObjectKey("recordings/abc/segments/1.m4a")).toBeNull();
    expect(parseObjectKey("other/20261125T091900Z-3f9a2c1b/manifest.json")).toBeNull();
  });
});

describe("auth", () => {
  it("SHA-256 が一致するトークンだけ通す", async () => {
    const hashes = await sha256Hex("device-token");
    const ok = new Request("https://x", { headers: { Authorization: "Bearer device-token" } });
    const bad = new Request("https://x", { headers: { Authorization: "Bearer other" } });
    const none = new Request("https://x");
    expect(await isAuthorized(ok, hashes)).toBe(true);
    expect(await isAuthorized(bad, hashes)).toBe(false);
    expect(await isAuthorized(none, hashes)).toBe(false);
    expect(await isAuthorized(ok, "")).toBe(false);
  });

  it("形の違う行は無視する", () => {
    expect(allowedHashes(` ${SHA.toUpperCase()} , nothex ,`)).toEqual([SHA]);
  });
});

describe("presign", () => {
  it("入力を検証する", () => {
    const valid = { key: KEY, contentType: "audio/mp4", contentLength: 1000, sha256: SHA };
    expect(validatePresignInput(valid)).toEqual(valid);
    expect(() => validatePresignInput({ ...valid, key: "x" })).toThrow();
    expect(() => validatePresignInput({ ...valid, contentType: "text/html" })).toThrow();
    expect(() => validatePresignInput({ ...valid, contentLength: 0 })).toThrow();
    expect(() => validatePresignInput({ ...valid, contentLength: 200 * 1024 * 1024 })).toThrow();
    expect(() => validatePresignInput({ ...valid, sha256: "abc" })).toThrow();
    expect(() => validatePresignInput(null)).toThrow();
  });

  it("hex を base64 にする", () => {
    expect(hexToBase64(SHA)).toBe("47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=");
  });

  it("S3 互換の署名付き PUT URL を作る", async () => {
    const now = new Date("2026-11-25T09:00:00Z");
    const out = await presignPut(
      { endpoint: "https://acc123.r2.cloudflarestorage.com", bucket: "voice-recordings", region: "auto", accessKeyId: "AKID", secretAccessKey: "s" },
      { key: KEY, contentType: "audio/mp4", contentLength: 10, sha256: SHA },
      { expiresIn: 900, checksum: true, now },
    );
    const url = new URL(out.url);
    expect(url.host).toBe("acc123.r2.cloudflarestorage.com");
    expect(url.pathname).toBe(`/voice-recordings/${KEY}`);
    expect(url.searchParams.get("X-Amz-Expires")).toBe("900");
    expect(url.searchParams.get("X-Amz-Date")).toBe("20261125T090000Z");
    expect(url.searchParams.get("X-Amz-Credential")).toBe("AKID/20261125/auto/s3/aws4_request");
    expect(url.searchParams.get("X-Amz-SignedHeaders")).toBe("host;x-amz-checksum-sha256") // aws4fetch は Content-Type を署名に含めない;
    expect(url.searchParams.get("X-Amz-Signature")).toMatch(/^[0-9a-f]{64}$/);
    expect(out.headers).toEqual({ "Content-Type": "audio/mp4", "x-amz-checksum-sha256": hexToBase64(SHA) });
    expect(out.expiresAt).toBe("2026-11-25T09:15:00Z");
  });
});

describe("fetch handler", () => {
  it("正しいトークンなら署名付きURLを返す", async () => {
    const res = await handleFetch(presignRequest({ key: KEY, contentType: "audio/mp4", contentLength: 10, sha256: SHA }), await env());
    expect(res.status).toBe(200);
    const body = (await res.json()) as { url: string; method: string; headers: Record<string, string> };
    expect(body.method).toBe("PUT");
    expect(body.url).toContain("https://acc123.r2.cloudflarestorage.com/voice-recordings/recordings/");
    expect(body.headers).toEqual({ "Content-Type": "audio/mp4" }); // REQUIRE_CHECKSUM 未設定
  });

  it("トークンが違えば 401", async () => {
    const res = await handleFetch(presignRequest({ key: KEY }, "wrong"), await env());
    expect(res.status).toBe(401);
  });

  it("キーが不正なら 400", async () => {
    const res = await handleFetch(presignRequest({ key: "../x", contentType: "audio/mp4", contentLength: 1, sha256: SHA }), await env());
    expect(res.status).toBe(400);
  });

  it("その他のパスは 404、GET は 405", async () => {
    expect((await handleFetch(new Request("https://x/"), await env())).status).toBe(404);
    expect((await handleFetch(new Request("https://x/v1/presign"), await env())).status).toBe(405);
    expect((await handleFetch(new Request("https://x/v1/health"), await env())).status).toBe(200);
  });
});

describe("replicate", () => {
  function fakeBucket(objects: Record<string, string>) {
    const puts: Record<string, string> = {};
    const bucket = {
      async get(key: string) {
        if (!(key in objects)) return null;
        const text = objects[key];
        return {
          body: new Blob([text]).stream(),
          httpMetadata: { contentType: "audio/mp4" },
          arrayBuffer: async () => new TextEncoder().encode(text).buffer,
        };
      },
      async put(key: string, body: ReadableStream) {
        puts[key] = await new Response(body).text();
      },
    };
    return { bucket: bucket as unknown as R2Bucket, puts };
  }

  it("録音のキーの作成イベントだけを複製する", () => {
    expect(shouldReplicate({ action: "PutObject", bucket: "b", object: { key: KEY } })).toBe(true);
    expect(shouldReplicate({ action: "DeleteObject", bucket: "b", object: { key: KEY } })).toBe(false);
    expect(shouldReplicate({ action: "PutObject", bucket: "b", object: { key: "tmp/x" } })).toBe(false);
  });

  it("R2 バインディングの宛先へコピーする", async () => {
    const primary = fakeBucket({ [KEY]: "audio" });
    const backup = fakeBucket({});
    await replicateObject(
      { RECORDINGS: primary.bucket, BACKUP: backup.bucket, REPLICA_TARGETS: JSON.stringify([{ id: "b", kind: "r2", binding: "BACKUP" }]) },
      { action: "PutObject", bucket: "voice-recordings", object: { key: KEY } },
    );
    expect(backup.puts[KEY]).toBe("audio");
  });

  it("S3 宛先へ署名付きで PUT し、失敗なら投げる（Queue が送り直す）", async () => {
    const primary = fakeBucket({ [KEY]: "audio" });
    const calls: Request[] = [];
    const target = { id: "s3", kind: "s3", endpoint: "https://s3.ap-northeast-1.amazonaws.com", bucket: "bk", region: "ap-northeast-1", accessKeyIdVar: "S3_KEY", secretAccessKeyVar: "S3_SECRET" };
    const envForS3 = { RECORDINGS: primary.bucket, S3_KEY: "AKID", S3_SECRET: "s", REPLICA_TARGETS: JSON.stringify([target]) };
    const message = { action: "PutObject", bucket: "voice-recordings", object: { key: KEY } };

    await replicateObject(envForS3, message, (async (req: Request) => {
      calls.push(req);
      return new Response(null, { status: 200 });
    }) as typeof fetch);
    expect(calls[0].url).toBe(`https://s3.ap-northeast-1.amazonaws.com/bk/${KEY}`);
    expect(calls[0].headers.get("authorization")).toContain("AWS4-HMAC-SHA256");

    await expect(
      replicateObject(envForS3, message, (async () => new Response(null, { status: 500 })) as typeof fetch),
    ).rejects.toThrow("HTTP 500");
  });
});
