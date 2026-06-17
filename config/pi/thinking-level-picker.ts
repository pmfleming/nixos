import type { ExtensionAPI, ThinkingLevel } from "@earendil-works/pi-coding-agent";
import { Key } from "@earendil-works/pi-tui";

const LEVELS = ["off", "minimal", "low", "medium", "high", "xhigh"] as const;
type Level = (typeof LEVELS)[number];

const DESCRIPTIONS: Record<Level, string> = {
  off: "no extended thinking",
  minimal: "fastest reasoning",
  low: "light reasoning",
  medium: "balanced reasoning",
  high: "deeper reasoning",
  xhigh: "maximum reasoning",
};

function isLevel(value: string): value is Level {
  return (LEVELS as readonly string[]).includes(value);
}

function normalizeLevel(value: string): Level | undefined {
  const normalized = value.trim().toLowerCase();
  if (normalized === "max") return "xhigh";
  if (normalized === "extra" || normalized === "extra-high" || normalized === "extra_high") return "xhigh";
  return isLevel(normalized) ? normalized : undefined;
}

export default function (pi: ExtensionAPI) {
  function statusText(): string {
    return `think:${pi.getThinkingLevel()}`;
  }

  function updateStatus(ctx: { ui: { setStatus: (id: string, value: string | undefined) => void } }) {
    ctx.ui.setStatus("thinking-level", statusText());
  }

  async function setLevel(rawLevel: string, ctx: { ui: { notify: (message: string, type: "info" | "warning" | "error") => void; setStatus: (id: string, value: string | undefined) => void } }) {
    const level = normalizeLevel(rawLevel);
    if (!level) {
      ctx.ui.notify(`Unknown thinking level: ${rawLevel}. Use: ${LEVELS.join(", ")}`, "error");
      return;
    }

    const before = pi.getThinkingLevel();
    pi.setThinkingLevel(level as ThinkingLevel);
    const after = pi.getThinkingLevel();
    updateStatus(ctx);

    if (after !== level) {
      ctx.ui.notify(`Requested ${level}, but current model clamped thinking to ${after}.`, "warning");
    } else if (after !== before) {
      ctx.ui.notify(`Thinking level set to ${after}.`, "info");
    } else {
      ctx.ui.notify(`Thinking level is already ${after}.`, "info");
    }
  }

  async function openPicker(ctx: Parameters<Parameters<typeof pi.registerCommand>[1]["handler"]>[1]) {
    const current = pi.getThinkingLevel();
    const choices = LEVELS.map((level) => {
      const marker = level === current ? "●" : "○";
      return `${marker} ${level.padEnd(7)} ${DESCRIPTIONS[level]}`;
    });

    const choice = await ctx.ui.select("Choose model thinking level", choices);
    if (!choice) return;

    const selected = choice.split(/\s+/)[1];
    await setLevel(selected, ctx);
  }

  pi.registerCommand("think", {
    description: "Choose model thinking level, or set one: /think high",
    handler: async (args, ctx) => {
      const requested = args.trim();
      if (requested) {
        await setLevel(requested, ctx);
      } else {
        await openPicker(ctx);
      }
    },
  });

  pi.registerCommand("thinking", {
    description: "Choose model thinking level, or set one: /thinking high",
    handler: async (args, ctx) => {
      const requested = args.trim();
      if (requested) {
        await setLevel(requested, ctx);
      } else {
        await openPicker(ctx);
      }
    },
  });

  pi.registerShortcut(Key.alt("t"), {
    description: "Choose thinking level",
    handler: async (ctx) => {
      await openPicker(ctx as Parameters<Parameters<typeof pi.registerCommand>[1]["handler"]>[1]);
    },
  });

  pi.on("session_start", async (_event, ctx) => {
    updateStatus(ctx);
  });

  pi.on("thinking_level_select", async (_event, ctx) => {
    updateStatus(ctx);
  });

  pi.on("model_select", async (_event, ctx) => {
    updateStatus(ctx);
  });
}
