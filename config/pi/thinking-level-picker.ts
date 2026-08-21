import type { ExtensionAPI, ThinkingLevel } from "@earendil-works/pi-coding-agent";
import { Key } from "@earendil-works/pi-tui";

type Level = ThinkingLevel;
type NotifyType = "info" | "warning" | "error";
type ThinkingUi = {
  notify: (message: string, type: NotifyType) => void;
  select: (title: string, choices: string[]) => Promise<string | undefined>;
  setStatus: (id: string, value: string | undefined) => void;
};
type ThinkingContext = { ui: ThinkingUi };

const LEVELS: Level[] = ["off", "minimal", "low", "medium", "high", "xhigh", "max"];
const DESCRIPTIONS: Record<Level, string> = {
  off: "no extended thinking",
  minimal: "fastest reasoning",
  low: "light reasoning",
  medium: "balanced reasoning",
  high: "deeper reasoning",
  xhigh: "very deep reasoning",
  max: "maximum unconstrained reasoning",
};
const ALIASES: Record<string, Level> = { extra: "xhigh", "extra-high": "xhigh", extra_high: "xhigh" };

function isLevel(value: string): value is Level {
  return LEVELS.some((level) => level === value);
}

function parseLevel(value: string): Level | undefined {
  const normalized = value.trim().toLowerCase();
  return ALIASES[normalized] ?? (isLevel(normalized) ? normalized : undefined);
}

function updateStatus(pi: ExtensionAPI, ctx: ThinkingContext): void {
  ctx.ui.setStatus("thinking-level", `think:${pi.getThinkingLevel()}`);
}

function notifyResult(pi: ExtensionAPI, ctx: ThinkingContext, requested: Level, before: ThinkingLevel): void {
  const after = pi.getThinkingLevel();
  if (after !== requested) ctx.ui.notify(`Requested ${requested}, but current model clamped thinking to ${after}.`, "warning");
  else if (after !== before) ctx.ui.notify(`Thinking level set to ${after}.`, "info");
  else ctx.ui.notify(`Thinking level is already ${after}.`, "info");
}

async function setLevel(pi: ExtensionAPI, rawLevel: string, ctx: ThinkingContext): Promise<void> {
  const level = parseLevel(rawLevel);
  if (!level) {
    ctx.ui.notify(`Unknown thinking level: ${rawLevel}. Use: ${LEVELS.join(", ")}`, "error");
    return;
  }

  const before = pi.getThinkingLevel();
  pi.setThinkingLevel(level);
  updateStatus(pi, ctx);
  notifyResult(pi, ctx, level, before);
}

async function openPicker(pi: ExtensionAPI, ctx: ThinkingContext): Promise<void> {
  const current = pi.getThinkingLevel();
  const choices = LEVELS.map((level) => `${level === current ? "●" : "○"} ${level.padEnd(7)} ${DESCRIPTIONS[level]}`);
  const choice = await ctx.ui.select("Choose model thinking level", choices);
  const level = choice ? LEVELS[choices.indexOf(choice)] : undefined;
  if (level) await setLevel(pi, level, ctx);
}

function handleThinkingCommand(pi: ExtensionAPI, args: string, ctx: ThinkingContext): Promise<void> {
  const requested = args.trim();
  return requested ? setLevel(pi, requested, ctx) : openPicker(pi, ctx);
}

export default function (pi: ExtensionAPI) {
  for (const name of ["think", "thinking"]) {
    pi.registerCommand(name, {
      description: `Choose model thinking level, or set one: /${name} high`,
      handler: async (args, ctx) => handleThinkingCommand(pi, args, ctx),
    });
  }

  pi.registerShortcut(Key.alt("t"), { description: "Choose thinking level", handler: async (ctx) => openPicker(pi, ctx) });
  pi.on("session_start", async (_event, ctx) => updateStatus(pi, ctx));
  pi.on("thinking_level_select", async (_event, ctx) => updateStatus(pi, ctx));
  pi.on("model_select", async (_event, ctx) => updateStatus(pi, ctx));
}
