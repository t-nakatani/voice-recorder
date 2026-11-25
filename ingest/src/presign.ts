import { AwsClient } from "aws4fetch";
import { ALLOWED_CONTENT_TYPES, parseObjectKey } from "./keys";

export type PresignInput = {
  key: string;
  contentType: string;
  contentLength: number;
  /** ファイルの SHA-256（小文字16進） */
  sha256: string;
};

export type PresignOutput = {
  url: string;
  method: "PUT";
  /** iPhone はこのヘッダーをそのまま付けて PUT する（署名に含まれている） */
  headers: Record<string, string>;
  expiresAt: string;
};

export type S3Target = {
  /** 例: https://<account>.r2.cloudflarestorage.com */
  endpoint: string;
  bucket: string;
  region: string;
  accessKeyId: string;
  secretAccessKey: string;
};

export const MAX_UPLOAD_BYTES = 100 * 1024 * 1024;

export class PresignError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

export function validatePresignInput(body: unknown): PresignInput {
  if (typeof body !== "object" || body === null) throw new PresignError(400, "JSON の object を送ってください");
  const { key, contentType, contentLength, sha256 } = body as Record<string, unknown>;
  if (typeof key !== "string") throw new PresignError(400, "key がありません");
  const parsed = parseObjectKey(key);
  if (!parsed) throw new PresignError(400, `このキーには置けません: ${key}`);
  if (typeof contentType !== "string" || !ALLOWED_CONTENT_TYPES[parsed.kind].includes(contentType)) {
    throw new PresignError(400, `contentType が不正です: ${String(contentType)}`);
  }
  if (typeof contentLength !== "number" || !Number.isInteger(contentLength) || contentLength <= 0 || contentLength > MAX_UPLOAD_BYTES) {
    throw new PresignError(400, "contentLength が不正です");
  }
  if (typeof sha256 !== "string" || !/^[0-9a-f]{64}$/.test(sha256)) throw new PresignError(400, "sha256 が不正です");
  return { key, contentType, contentLength, sha256 };
}

export function hexToBase64(hex: string): string {
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < bytes.length; i++) bytes[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary);
}

/**
 * S3 互換 API の署名付き PUT URL を作る。R2 でも AWS S3 でも同じ。
 * checksum を true にすると x-amz-checksum-sha256 を署名に含め、保存先が中身を検証する。
 */
export async function presignPut(
  target: S3Target,
  input: PresignInput,
  options: { expiresIn: number; checksum: boolean; now?: Date },
): Promise<PresignOutput> {
  const client = new AwsClient({
    accessKeyId: target.accessKeyId,
    secretAccessKey: target.secretAccessKey,
    service: "s3",
    region: target.region,
  });
  const url = new URL(`${target.endpoint.replace(/\/$/, "")}/${target.bucket}/${input.key}`);
  url.searchParams.set("X-Amz-Expires", String(options.expiresIn));

  const headers: Record<string, string> = { "Content-Type": input.contentType };
  if (options.checksum) headers["x-amz-checksum-sha256"] = hexToBase64(input.sha256);

  const signed = await client.sign(new Request(url, { method: "PUT", headers }), {
    aws: { signQuery: true, datetime: options.now ? amzDate(options.now) : undefined },
  });
  const now = options.now ?? new Date();
  return {
    url: signed.url,
    method: "PUT",
    headers,
    expiresAt: new Date(now.getTime() + options.expiresIn * 1000).toISOString().replace(/\.\d{3}Z$/, "Z"),
  };
}

function amzDate(date: Date): string {
  return date.toISOString().replace(/[:-]|\.\d{3}/g, "");
}
