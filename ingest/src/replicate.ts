import { AwsClient } from "aws4fetch";
import type { S3Target } from "./presign";
import { parseObjectKey } from "./keys";

/**
 * 主宛先（R2）に置かれたものを、他の宛先へコピーする。
 * R2 のイベント通知 → Queue → この consumer、という流れ。失敗したら Queue が送り直し、
 * それでもだめならデッドレターキューに残る（iPhone 側には元のファイルが残っているので失われない）。
 */

export type ReplicaTarget =
  | { id: string; kind: "r2"; binding: string }
  | { id: string; kind: "s3"; endpoint: string; bucket: string; region: string; accessKeyIdVar: string; secretAccessKeyVar: string };

/** R2 イベント通知のメッセージ（必要な部分だけ） */
export type R2EventMessage = {
  action: string;
  bucket: string;
  object: { key: string; size?: number; eTag?: string };
};

export function parseReplicaTargets(raw: string | undefined): ReplicaTarget[] {
  if (!raw || raw.trim() === "") return [];
  const parsed = JSON.parse(raw) as ReplicaTarget[];
  if (!Array.isArray(parsed)) throw new Error("REPLICA_TARGETS は配列の JSON にしてください");
  return parsed;
}

export type ReplicateEnv = {
  RECORDINGS: R2Bucket;
  REPLICA_TARGETS?: string;
  [name: string]: unknown;
};

export function shouldReplicate(message: R2EventMessage): boolean {
  return (message.action === "PutObject" || message.action === "CompleteMultipartUpload" || message.action === "CopyObject")
    && parseObjectKey(message.object.key) !== null;
}

export async function replicateObject(env: ReplicateEnv, message: R2EventMessage, fetcher: typeof fetch = fetch): Promise<void> {
  if (!shouldReplicate(message)) return;
  const targets = parseReplicaTargets(env.REPLICA_TARGETS);
  for (const target of targets) {
    const object = await env.RECORDINGS.get(message.object.key);
    if (!object) return; // 既に消えている（手で消した等）なら何もしない
    const contentType = object.httpMetadata?.contentType ?? "application/octet-stream";
    if (target.kind === "r2") {
      const bucket = env[target.binding] as R2Bucket | undefined;
      if (!bucket) throw new Error(`R2 バインディング ${target.binding} がありません`);
      await bucket.put(message.object.key, object.body, { httpMetadata: { contentType } });
    } else {
      const s3: S3Target = {
        endpoint: target.endpoint,
        bucket: target.bucket,
        region: target.region,
        accessKeyId: String(env[target.accessKeyIdVar] ?? ""),
        secretAccessKey: String(env[target.secretAccessKeyVar] ?? ""),
      };
      if (!s3.accessKeyId || !s3.secretAccessKey) throw new Error(`宛先 ${target.id} の鍵が設定されていません`);
      const client = new AwsClient({ accessKeyId: s3.accessKeyId, secretAccessKey: s3.secretAccessKey, service: "s3", region: s3.region });
      const url = `${s3.endpoint.replace(/\/$/, "")}/${s3.bucket}/${message.object.key}`;
      // 区切りは小さい（1分 0.5MB 程度）ので、一度読み切ってから送る
      const body = await object.arrayBuffer();
      const signed = await client.sign(url, { method: "PUT", body, headers: { "Content-Type": contentType } });
      const response = await fetcher(signed);
      if (!response.ok) throw new Error(`宛先 ${target.id} への複製に失敗: HTTP ${response.status}`);
    }
  }
}
