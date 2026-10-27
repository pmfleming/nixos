/** Narrow untrusted JSON/OS inputs without asserting that they already satisfy a schema. */
export function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
export function object(value: unknown): Record<string, unknown> {
  return isRecord(value) ? value : {};
}
export function requireObject(value: unknown): Record<string, unknown> {
  if (!isRecord(value)) throw new Error("Malformed worker state/attachment object");
  return value;
}
export function errorCode(error: unknown): unknown { return object(error).code; }
export function array(value: unknown): unknown[] { return Array.isArray(value) ? value : []; }
export function strings(value: unknown): value is string[] {
  return Array.isArray(value) && value.every((item: unknown) => typeof item === "string");
}
