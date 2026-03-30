# ClaudeNotifier & Status Bar — Demo Scenarios

### 1. Menu bar: session states

**What to show:** Title cycling through all three states.

1. Open a new Claude Code session in a project directory — status item changes to `✳ 1 claudeship`
2. Submit any prompt — title switches to `⣾ 1/1 claudeship` with spinner
3. Wait for the turn to finish — spinner stops, returns to `✳ 1 claudeship`
4. Open a second session in a different directory — title shows `✳ 2 claudeship`
5. Submit a prompt in one session — shows `⣾ 1/2 claudeship`
6. Exit both sessions — title returns to `✳ claudeship`

---

### 2. Menu bar: dropdown + focus

**What to show:** Session list with working/idle indicators, clicking focuses the window.

1. Open two sessions in different directories (e.g. `claudeship`, `myproject`)
2. Click the status item — see both listed with `○  name  —  idle`
3. Submit a prompt in one — click again, that entry now shows `●  name  —  working`
4. Switch away from Ghostty (e.g. open Safari), then click the session entry — Ghostty window for that directory comes to front

---

### 3. Subagent progress notifications

**What to show:** `"Agent Name done (1/2)"` notifications as parallel agents complete.

1. Submit a prompt that spawns multiple subagents, e.g.:
   > "Use two agents in parallel: one to list files in `/tmp`, one to check the current date"
2. Menu bar dropdown shows subagents indented under the parent session while they run
3. Each agent completion fires a notification: `"fast-agent done (1/2)"`, `"fast-agent done (2/2)"`
4. After the turn ends, subagents disappear from the dropdown

---

### 4. Interactive input — AskUserQuestion

**What to show:** Notification with option buttons; Claude gets the answer without terminal focus.

1. Switch away from Ghostty so the terminal is not focused
2. Submit a prompt that forces a choice, e.g.:
   > "Ask me whether I want output as JSON or plain text, then print 'hello world' in that format"
3. A notification appears with "JSON" and "Plain text" buttons
4. Tap a button — Claude continues and responds in the chosen format without you switching back to the terminal

---

### 5. Plan mode notification

**What to show:** Informational banner when a plan is ready for approval.

1. Enter plan mode (`/plan`) and give Claude a task
2. Switch away from Ghostty
3. When Claude finishes planning, a `"Plan ready — awaiting your approval"` notification fires
4. Switch back to approve or reject

---

### 6. Permission request

**What to show:** Actionable notification replacing the in-terminal approval dialog.

1. Set a tool to require approval (e.g. add `Bash` to `settings.json` permissions ask list, or use a tool that isn't pre-approved)
2. Switch away from Ghostty
3. Submit a prompt that triggers the tool
4. Notification appears with **"Yes"**, **"Yes, allow Bash from ..."**, and **"No"** buttons
5. Tap a button — Claude proceeds or is denied without switching back to the terminal

---

### 7. Elicitation (MCP server input)

**What to show:** Notification when an MCP server requests user input mid-tool-call.

1. Have an MCP server configured that calls `elicitation`
2. Trigger the relevant tool
3. A notification fires with the elicitation message — switch back to terminal to respond (elicitation is informational only, no buttons)

---

### 8. Stop failure

**What to show:** Error notification when a turn ends due to an API error.

1. Trigger an API error (e.g. submit a prompt while temporarily offline, or with an invalid API key in a secondary profile)
2. A `"Error: ..."` notification fires with the Basso sound instead of Ping

---

### 9. BEL vs notification (stop.sh)

**What to show:** Different behavior depending on whether Ghostty is focused.

1. Keep Ghostty focused, submit a long-running prompt, wait for it to finish — Ghostty adds 🔔 to the tab title (BEL), no system notification
2. Submit another prompt, switch to a different app while it runs, wait for finish — macOS notification fires instead
