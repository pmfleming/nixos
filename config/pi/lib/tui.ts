import type { Theme } from "@earendil-works/pi-coding-agent";
import { matchesKey, truncateToWidth } from "@earendil-works/pi-tui";

export function selectTheme(theme: Pick<Theme, "fg">) {
  const accent = (text: string) => theme.fg("accent", text), dim = (text: string) => theme.fg("dim", text);
  return { selectedPrefix: accent, selectedText: accent, description: (text: string) => theme.fg("muted", text), scrollInfo: dim, noMatch: dim };
}
export function workerShortcut(data: string): number | undefined {
  return ([1, 2, 3, 4, 5, 6, 7, 8, 9] as const).find(number => matchesKey(data, `alt+${number}`));
}
export function fitLines(lines: string[], width: number, height: number): string[] {
  return lines.slice(0, Math.max(1, height)).map(line => truncateToWidth(line, Math.max(0, width)));
}
