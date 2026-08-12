import { Key, matchesKey, truncateToWidth, visibleWidth, type Component, type KeyId } from "@earendil-works/pi-tui";
import { DISPLAY_LIMIT, formatDate, projectIcon, sessionSummary } from "./sessions.ts";
import type { SessionGroup, SessionRow } from "./types.ts";

export type SidebarChoice =
  | { action: "continue"; group: SessionGroup; session: SessionRow }
  | { action: "new"; group: SessionGroup }
  | { action: "rename"; group: SessionGroup; session: SessionRow }
  | { action: "pin"; group: SessionGroup; session: SessionRow }
  | null;

export type SidebarTheme = {
  fg?: (color: string, text: string) => string;
  bold?: (text: string) => string;
};

type VisibleRow =
  | { type: "group"; group: SessionGroup }
  | { type: "new"; group: SessionGroup }
  | { type: "session"; group: SessionGroup; session: SessionRow }
  | { type: "more"; group: SessionGroup; hidden: number };

export class RecentSessionsSidebar implements Component {
  private selected = 0;
  private offset = 0;
  private expandedGroups = new Set<string>();
  private showAllGroups = new Set<string>();
  private cachedWidth?: number;
  private cachedRowsSignature?: string;
  private cachedLines?: string[];

  constructor(
    private groups: SessionGroup[],
    private currentSessionPath: string | undefined,
    private theme: SidebarTheme,
    private getTerminalRows: () => number,
    private done: (value: SidebarChoice) => void,
  ) {
    const initialGroup = groups.find((group) => group.hasCurrent) ?? groups[0];
    if (initialGroup) this.expandedGroups.add(initialGroup.key);

    const currentIndex = this.visibleRows().findIndex((row) => row.type === "session" && row.session.path === currentSessionPath);
    this.selected = currentIndex >= 0 ? currentIndex : 0;
    this.ensureVisible(this.visibleCount(), this.visibleRows().length);
  }

  handleInput(data: string): void {
    if (matchesKey(data, Key.escape) || matchesKey(data, Key.ctrl("c"))) {
      this.done(null);
      return;
    }

    const row = this.currentRow();
    if (!this.handleRowAction(data, row)) this.handleNavigation(data);
  }

  private handleRowAction(data: string, row: VisibleRow | undefined): boolean {
    if (matchesKey(data, Key.enter)) {
      if (row?.type === "group") this.toggleGroup(row.group.key);
      else if (row?.type === "new") this.done({ action: "new", group: row.group });
      else if (row?.type === "session") this.done({ action: "continue", group: row.group, session: row.session });
      else if (row?.type === "more") this.showOlder(row.group.key);
      return true;
    }

    if (matchesKey(data, Key.space)) {
      if (row?.type === "group") this.toggleGroup(row.group.key);
      return true;
    }

    if (matchesKey(data, Key.right)) {
      if (row?.type === "group") {
        if (this.expandedGroups.has(row.group.key)) this.selectFirstSession(row.group.key);
        else this.toggleGroup(row.group.key);
      } else if (row?.type === "more") {
        this.showOlder(row.group.key);
      }
      return true;
    }

    if (matchesKey(data, Key.left)) {
      if (row?.type === "group" && this.expandedGroups.has(row.group.key)) this.toggleGroup(row.group.key);
      else if (row?.type === "new" || row?.type === "session" || row?.type === "more") this.selectGroup(row.group.key);
      return true;
    }

    if (matchesKey(data, "r") || matchesKey(data, "shift+r")) {
      if (row?.type === "session") this.done({ action: "rename", group: row.group, session: row.session });
      return true;
    }

    if (matchesKey(data, "p") || matchesKey(data, "shift+p")) {
      if (row?.type === "session") this.done({ action: "pin", group: row.group, session: row.session });
      return true;
    }

    if (matchesKey(data, "n") || matchesKey(data, "shift+n")) {
      if (row) this.done({ action: "new", group: row.group });
      return true;
    }

    return false;
  }

  private handleNavigation(data: string): void {
    const page = Math.max(1, this.visibleCount() - 1);
    const movements: Array<[KeyId, number]> = [
      [Key.up, -1],
      [Key.down, 1],
      [Key.pageUp, -page],
      [Key.pageDown, page],
    ];
    const movement = movements.find(([key]) => matchesKey(data, key));
    if (movement) {
      this.move(movement[1]);
      return;
    }

    if (matchesKey(data, Key.home)) {
      this.selected = 0;
      this.offset = 0;
      this.invalidate();
      return;
    }

    if (matchesKey(data, Key.end)) {
      const rows = this.visibleRows();
      this.selected = Math.max(0, rows.length - 1);
      this.ensureVisible(this.visibleCount(), rows.length);
      this.invalidate();
    }
  }

  render(width: number): string[] {
    const rows = this.visibleRows();
    const visibleCount = this.visibleCount();
    const signature = `${rows.length}:${visibleCount}:${this.selected}:${this.offset}:${[...this.expandedGroups].sort().join(",")}:${[...this.showAllGroups].sort().join(",")}`;
    if (this.cachedLines && this.cachedWidth === width && this.cachedRowsSignature === signature) return this.cachedLines;

    if (rows.length > 0) this.selected = Math.max(0, Math.min(this.selected, rows.length - 1));
    else this.selected = 0;
    this.ensureVisible(visibleCount, rows.length);

    const totalSessions = this.groups.reduce((sum, group) => sum + group.sessions.length, 0);
    const projectCount = this.groups.filter((group) => group.kind !== "chats").length;
    const lines: string[] = [];

    lines.push(this.frameLine("┌", "─", "┐", width));
    lines.push(this.contentLine(this.accent(this.bold("Recent chats by project")), width));
    lines.push(this.contentLine(this.dim("↑/↓ select · ←/→ collapse/expand · Enter open · N new · R rename · P pin · Esc close"), width));
    lines.push(this.frameLine("├", "─", "┤", width));

    if (totalSessions === 0) {
      lines.push(this.contentLine("No saved chats found", width));
      this.pushBlankLines(lines, width, Math.max(0, visibleCount - 1));
    } else {
      const slice = rows.slice(this.offset, this.offset + visibleCount);
      for (const [visibleIndex, row] of slice.entries()) {
        const index = this.offset + visibleIndex;
        lines.push(this.renderRow(row, width, index === this.selected));
      }
      this.pushBlankLines(lines, width, Math.max(0, visibleCount - slice.length));
    }

    lines.push(this.frameLine("├", "─", "┤", width));
    const footer = [`${totalSessions} chats`, `${projectCount} projects`];
    if (rows.length) footer.push(`${this.selected + 1}/${rows.length}`);
    lines.push(this.contentLine(this.dim(footer.join(" · ")), width));
    lines.push(this.frameLine("└", "─", "┘", width));

    this.cachedWidth = width;
    this.cachedRowsSignature = signature;
    this.cachedLines = lines.map((line) => truncateToWidth(line, width, ""));
    return this.cachedLines;
  }

  invalidate(): void {
    this.cachedWidth = undefined;
    this.cachedRowsSignature = undefined;
    this.cachedLines = undefined;
  }

  private displayedSessions(group: SessionGroup): SessionRow[] {
    if (this.showAllGroups.has(group.key) || group.sessions.length <= DISPLAY_LIMIT) return group.sessions;
    const displayed = group.sessions.slice(0, DISPLAY_LIMIT);
    const current = group.sessions.find((session) => session.path === this.currentSessionPath);
    if (current && !displayed.some((session) => session.path === current.path)) {
      displayed[displayed.length - 1] = current;
      displayed.sort((a, b) => b.modified.getTime() - a.modified.getTime());
    }
    return displayed;
  }

  private visibleRows(): VisibleRow[] {
    const rows: VisibleRow[] = [];
    for (const group of this.groups) {
      rows.push({ type: "group", group });
      if (this.expandedGroups.has(group.key)) {
        rows.push({ type: "new", group });
        const displayed = this.displayedSessions(group);
        for (const session of displayed) rows.push({ type: "session", group, session });
        const hidden = group.sessions.length - displayed.length;
        if (hidden > 0) rows.push({ type: "more", group, hidden });
      }
    }
    return rows;
  }

  private currentRow(): VisibleRow | undefined {
    return this.visibleRows()[this.selected];
  }

  private toggleGroup(key: string): void {
    if (this.expandedGroups.has(key)) this.expandedGroups.delete(key);
    else this.expandedGroups.add(key);
    const rows = this.visibleRows();
    this.selected = Math.max(0, Math.min(this.selected, rows.length - 1));
    this.ensureVisible(this.visibleCount(), rows.length);
    this.invalidate();
  }

  private showOlder(key: string): void {
    this.showAllGroups.add(key);
    this.invalidate();
  }

  private selectGroup(key: string): void {
    const index = this.visibleRows().findIndex((row) => row.type === "group" && row.group.key === key);
    if (index >= 0) {
      this.selected = index;
      this.ensureVisible(this.visibleCount(), this.visibleRows().length);
      this.invalidate();
    }
  }

  private selectFirstSession(key: string): void {
    const index = this.visibleRows().findIndex((row) => (row.type === "new" || row.type === "session") && row.group.key === key);
    if (index >= 0) {
      this.selected = index;
      this.ensureVisible(this.visibleCount(), this.visibleRows().length);
      this.invalidate();
    }
  }

  private move(delta: number): void {
    const rows = this.visibleRows();
    if (rows.length === 0) return;
    this.selected = Math.max(0, Math.min(rows.length - 1, this.selected + delta));
    this.ensureVisible(this.visibleCount(), rows.length);
    this.invalidate();
  }

  private visibleCount(): number {
    // 7 chrome lines: top border, title, help, separator, footer separator, footer, bottom border.
    return Math.max(1, this.getTerminalRows() - 7);
  }

  private ensureVisible(visibleCount: number, rowCount: number): void {
    if (rowCount <= 0) {
      this.offset = 0;
      return;
    }
    const maxOffset = Math.max(0, rowCount - visibleCount);
    if (this.selected < this.offset) this.offset = this.selected;
    if (this.selected >= this.offset + visibleCount) this.offset = this.selected - visibleCount + 1;
    this.offset = Math.max(0, Math.min(this.offset, maxOffset));
  }

  private renderRow(row: VisibleRow, width: number, selected: boolean): string {
    if (row.type === "group") {
      const expanded = this.expandedGroups.has(row.group.key);
      const marker = selected ? "›" : " ";
      const arrow = expanded ? "▾" : "▸";
      const active = row.group.hasCurrent ? "●" : " ";
      const icon = projectIcon(row.group.kind);
      const latest = formatDate(new Date(row.group.latestMs));
      return this.contentLine(`${marker} ${arrow} ${active} ${icon} ${row.group.label} (${row.group.sessions.length}) · ${latest}`, width, selected);
    }

    const marker = selected ? "›" : " ";
    if (row.type === "new") {
      return this.contentLine(`${marker}     ＋ New chat in this project`, width, selected);
    }
    if (row.type === "more") {
      return this.contentLine(`${marker}     … Show ${row.hidden} older chat${row.hidden === 1 ? "" : "s"}`, width, selected);
    }

    const currentMarker = row.session.path === this.currentSessionPath ? "●" : row.session.pinned ? "◆" : " ";
    return this.contentLine(`${marker}     ${currentMarker} ${sessionSummary(row.session)}`, width, selected);
  }

  private pushBlankLines(lines: string[], width: number, count: number): void {
    for (let i = 0; i < count; i++) lines.push(this.contentLine("", width));
  }

  private contentLine(text: string, width: number, selected = false): string {
    const innerWidth = Math.max(1, width - 4);
    let content = truncateToWidth(text, innerWidth, "");
    const pad = Math.max(0, innerWidth - visibleWidth(content));
    content = content + " ".repeat(pad);
    if (selected) content = `\x1b[7m${content}\x1b[27m`;
    return `${this.border("│")} ${content} ${this.border("│")}`;
  }

  private frameLine(left: string, fill: string, right: string, width: number): string {
    return this.border(left + fill.repeat(Math.max(0, width - 2)) + right);
  }

  private border(text: string): string {
    return this.theme.fg?.("border", text) ?? text;
  }

  private accent(text: string): string {
    return this.theme.fg?.("accent", text) ?? text;
  }

  private dim(text: string): string {
    return this.theme.fg?.("dim", text) ?? text;
  }

  private bold(text: string): string {
    return this.theme.bold?.(text) ?? text;
  }
}
