// バケット内のキーの形。iOS 側 RecorderCore/ObjectKeys.swift と揃える。
// 録音ID: 20261125T091900Z-3f9a2c1b のような英数字とハイフン
const RECORDING_ID = "[0-9A-Za-z][0-9A-Za-z-]{5,63}";
const KEY_PATTERN = new RegExp(`^recordings/(${RECORDING_ID})/(segments/\\d{6}\\.(m4a|caf|wav)|manifest\\.json)$`);

export type ParsedKey = { recordingId: string; kind: "segment" | "manifest" };

export function parseObjectKey(key: string): ParsedKey | null {
  const match = KEY_PATTERN.exec(key);
  if (!match) return null;
  return { recordingId: match[1], kind: match[2] === "manifest.json" ? "manifest" : "segment" };
}

export const ALLOWED_CONTENT_TYPES: Record<ParsedKey["kind"], string[]> = {
  segment: ["audio/mp4", "audio/x-caf", "audio/wav"],
  manifest: ["application/json"],
};
