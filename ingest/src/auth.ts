// 端末トークンの確認。Worker にはトークンそのものではなく SHA-256 だけを置く（DEVICE_TOKEN_SHA256 にカンマ区切り）。
// 端末を失くしたら、その行を消して再デプロイ（または secret を更新）すれば無効になる。

export async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export function allowedHashes(raw: string | undefined): string[] {
  return (raw ?? "")
    .split(",")
    .map((s) => s.trim().toLowerCase())
    .filter((s) => /^[0-9a-f]{64}$/.test(s));
}

export async function isAuthorized(request: Request, rawHashes: string | undefined): Promise<boolean> {
  const header = request.headers.get("Authorization") ?? "";
  const match = /^Bearer\s+(.+)$/.exec(header);
  if (!match) return false;
  const presented = await sha256Hex(match[1].trim());
  let ok = false;
  for (const hash of allowedHashes(rawHashes)) ok = timingSafeEqual(presented, hash) || ok;
  return ok;
}
