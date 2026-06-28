import type { SessionManager } from "@earendil-works/pi-coding-agent";

export const CONTINUE = "Continue chat in new window";
export const NEW_CHAT = "New chat in this project";
export const RENAME = "Rename chat";
export const BACK = "Back";
export const CANCEL = "Cancel";
export const SESSION_ACTIONS = [CONTINUE, NEW_CHAT, RENAME, BACK, CANCEL];

export type SessionInfo = Awaited<ReturnType<typeof SessionManager.listAll>>[number];
export type ProjectKind = "git" | "folder" | "chats";
export type ProjectInfo = {
  key: string;
  label: string;
  cwd?: string;
  kind: ProjectKind;
};
export type SessionRow = SessionInfo & { project: ProjectInfo; branch?: string };
export type SessionGroup = ProjectInfo & { latestMs: number; sessions: SessionRow[]; hasCurrent: boolean };
export type RecentUi = {
  notify: (message: string, type: "info" | "warning" | "error") => void;
  input: (title: string, placeholder?: string) => Promise<string | undefined>;
  select: (title: string, choices: string[]) => Promise<string | undefined>;
};
export type RecentContext = {
  cwd: string;
  hasUI: boolean;
  sessionManager: { getSessionFile: () => string | undefined };
  ui: RecentUi;
};
