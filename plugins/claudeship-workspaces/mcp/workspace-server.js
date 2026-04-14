#!/usr/bin/env node
"use strict";
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
Object.defineProperty(exports, "__esModule", { value: true });
const index_js_1 = require("@modelcontextprotocol/sdk/server/index.js");
const stdio_js_1 = require("@modelcontextprotocol/sdk/server/stdio.js");
const types_js_1 = require("@modelcontextprotocol/sdk/types.js");
const child_process_1 = require("child_process");
const path = __importStar(require("path"));
const fs = __importStar(require("fs"));
// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------
// MCP uses stdout for protocol — all diagnostic logging goes to stderr
function log(msg) {
    process.stderr.write(`[claudeship] ${msg}\n`);
}
function loadUserConfig() {
    const p = path.join(process.env.HOME ?? "", ".claude", "claudeship.json");
    try {
        const cfg = JSON.parse(fs.readFileSync(p, "utf8"));
        log(`config: loaded user config from ${p}`);
        return cfg;
    }
    catch {
        log(`config: no user config at ${p} (using defaults)`);
        return {};
    }
}
function loadProjectConfig() {
    const p = path.join(getRepoRoot(), ".claudeship.json");
    try {
        const cfg = JSON.parse(fs.readFileSync(p, "utf8"));
        log(`config: loaded project config from ${p}`);
        return cfg;
    }
    catch {
        log(`config: no project config at ${p} (using defaults)`);
        return {};
    }
}
function resolveConfig() {
    const user = loadUserConfig();
    const project = loadProjectConfig();
    // Terminal: user config > $TERM_PROGRAM > empty
    const terminal = user.terminal ?? process.env.TERM_PROGRAM?.toLowerCase();
    if (user.terminal) {
        log(`config: terminal = "${terminal}" (from user config)`);
    }
    else if (process.env.TERM_PROGRAM) {
        log(`config: terminal = "${terminal}" (from $TERM_PROGRAM)`);
    }
    else {
        log(`config: terminal = none (no user config or $TERM_PROGRAM)`);
    }
    // Claude command: project > user > default
    let claudeSource;
    const claude = project.commands?.claude ?? user.commands?.claude ?? "claude";
    if (project.commands?.claude) {
        claudeSource = "project config";
    }
    else if (user.commands?.claude) {
        claudeSource = "user config";
    }
    else {
        claudeSource = "default";
    }
    log(`config: claude command = "${claude}" (from ${claudeSource})`);
    // Lifecycle: project only
    const lifecycle = project.workspace?.lifecycle;
    if (lifecycle) {
        log(`config: lifecycle.setup = ${lifecycle.setup ? `"${lifecycle.setup}"` : "(empty)"}`);
        log(`config: lifecycle.run = ${lifecycle.run ? `"${lifecycle.run}"` : "(empty)"}`);
        log(`config: lifecycle.teardown = ${lifecycle.teardown ? `"${lifecycle.teardown}"` : "(empty)"}`);
    }
    else {
        log(`config: no lifecycle scripts configured`);
    }
    return {
        terminal,
        commands: { claude },
        workspace: project.workspace,
    };
}
function runLifecycleScript(phase, script, env) {
    if (!script || script.trim() === "") {
        log(`lifecycle: ${phase} — skipped (no script configured)`);
        return { ok: true, output: "" };
    }
    log(`lifecycle: ${phase} — running: ${script}`);
    log(`lifecycle: ${phase} — cwd: ${env.WORKSPACE_PATH}`);
    log(`lifecycle: ${phase} — env: WORKSPACE_NAME=${env.WORKSPACE_NAME}, MAIN_CHECKOUT=${env.MAIN_CHECKOUT}`);
    try {
        const output = (0, child_process_1.execSync)(script, {
            cwd: env.WORKSPACE_PATH,
            encoding: "utf8",
            env: { ...process.env, ...env },
            timeout: 300_000, // 5 minute timeout for lifecycle scripts
        });
        log(`lifecycle: ${phase} — completed successfully`);
        return { ok: true, output: output.trim() };
    }
    catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        log(`lifecycle: ${phase} — FAILED: ${msg}`);
        return { ok: false, output: msg };
    }
}
// Plugin location — used only to locate workspace.sh
const PLUGIN_DIR = path.resolve(__dirname, "..");
const WORKSPACE_SH = path.join(PLUGIN_DIR, "workspace.sh");
// Repo root — resolved from the working directory Claude Code was launched in
let _repoRoot = null;
function getRepoRoot() {
    if (!_repoRoot) {
        _repoRoot = (0, child_process_1.execSync)("git rev-parse --show-toplevel", {
            cwd: process.cwd(),
            encoding: "utf8",
        }).trim();
    }
    return _repoRoot;
}
function getWorktreeRoot() {
    const repoRoot = getRepoRoot();
    const repoName = path.basename(repoRoot);
    return path.join(path.dirname(repoRoot), `${repoName}-worktrees`);
}
function getBranchPrefix() {
    try {
        const name = (0, child_process_1.execSync)("git config user.name", { cwd: getRepoRoot() })
            .toString()
            .trim();
        return name.toLowerCase().replace(/\s+/g, "-");
    }
    catch {
        return "unknown";
    }
}
function worktreePath(name) {
    return path.join(getWorktreeRoot(), name);
}
// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
function run(cmd, opts = {}) {
    return (0, child_process_1.execSync)(cmd, {
        cwd: opts.cwd ?? getRepoRoot(),
        encoding: "utf8",
    }).trim();
}
function runWorkspaceSh(...args) {
    return run(`bash "${WORKSPACE_SH}" ${args.map((a) => `"${a}"`).join(" ")}`);
}
function worktreeExists(name) {
    try {
        const wt = worktreePath(name);
        const out = run("git worktree list --porcelain");
        return out.includes(`worktree ${wt}`);
    }
    catch {
        return false;
    }
}
function listWorktreeNames() {
    try {
        const worktreeRoot = getWorktreeRoot();
        const out = run("git worktree list --porcelain");
        const names = [];
        for (const line of out.split("\n")) {
            const m = line.match(/^worktree (.+)$/);
            if (m && m[1] !== getRepoRoot() && m[1].startsWith(worktreeRoot)) {
                names.push(path.basename(m[1]));
            }
        }
        return names;
    }
    catch {
        return [];
    }
}
// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------
const server = new index_js_1.Server({ name: "workspace", version: "0.0.1" }, { capabilities: { tools: {} } });
// ---------------------------------------------------------------------------
// Tool definitions
// ---------------------------------------------------------------------------
server.setRequestHandler(types_js_1.ListToolsRequestSchema, async () => ({
    tools: [
        {
            name: "workspace_suggest",
            description: "Decides whether a task warrants a workspace and suggests a kebab-case name. " +
                "Always call this before workspace_create — it is the policy gate. " +
                "\n\nRecommend YES (recommend: true) when the task needs any of: " +
                "(1) isolation — parallel work that would conflict with main or another workspace; " +
                "(2) a running stack — the work requires services to develop or test; " +
                "(3) its own branch — the change is going somewhere independently. " +
                "\n\nRecommend NO (recommend: false) when the task is: " +
                "reading or understanding code; a single-file or docs-only edit; " +
                "a question or debugging session with no writes; a change that needs no running stack to validate; " +
                "or already covered by an existing workspace (return that workspace's name instead). " +
                "\n\nWhen in doubt, lean toward NO — workspace overhead is only worth it when isolation genuinely matters.",
            inputSchema: {
                type: "object",
                properties: {
                    task: {
                        type: "string",
                        description: "A short description of the task or feature you are about to work on.",
                    },
                },
                required: ["task"],
            },
        },
        {
            name: "workspace_create",
            description: "Creates an isolated workspace for a task: git worktree on a new branch, " +
                "a workspace-specific CLAUDE.md with task context, and runs project-configured lifecycle scripts (setup, run). " +
                "Also creates .workspace/research.md and .workspace/plan.md as artifact stubs for the research subagent to populate. " +
                "Use after workspace_suggest confirms a workspace is warranted. " +
                "Returns the worktree path and lifecycle results.",
            inputSchema: {
                type: "object",
                properties: {
                    name: {
                        type: "string",
                        description: "Short kebab-case workspace name (e.g. 'auth-refactor', 'payment-feature').",
                    },
                    task: {
                        type: "string",
                        description: "One or two sentence description of what this workspace is for. Written into the workspace CLAUDE.md.",
                    },
                },
                required: ["name", "task"],
            },
        },
        {
            name: "workspace_open",
            description: "Opens a new Claude Code session in the workspace's worktree directory, then returns. " +
                "Call this after workspace_create and after the .workspace/ artifact files have been populated by the research subagent. " +
                "This is the handoff point — the new session will have full ambient context from the workspace CLAUDE.md.",
            inputSchema: {
                type: "object",
                properties: {
                    name: {
                        type: "string",
                        description: "Workspace name to open.",
                    },
                },
                required: ["name"],
            },
        },
        {
            name: "workspace_list",
            description: "Lists all workspaces with their branch, last commit, and worktree path. " +
                "Use to check what workspaces exist before creating a new one, or to get an overview of active work.",
            inputSchema: {
                type: "object",
                properties: {},
            },
        },
        {
            name: "workspace_status",
            description: "Returns detailed status for a single workspace: branch, commits ahead/behind, and last commit. " +
                "Use when you need to check on a workspace's git state.",
            inputSchema: {
                type: "object",
                properties: {
                    name: {
                        type: "string",
                        description: "Workspace name.",
                    },
                },
                required: ["name"],
            },
        },
        {
            name: "workspace_destroy",
            description: "Runs the teardown lifecycle script, then removes the worktree and branch for a workspace. " +
                "Use after work is complete and merged, or to clean up abandoned workspaces. " +
                "Keeps the branch if it has unmerged commits.",
            inputSchema: {
                type: "object",
                properties: {
                    name: {
                        type: "string",
                        description: "Workspace name to destroy.",
                    },
                },
                required: ["name"],
            },
        },
    ],
}));
// ---------------------------------------------------------------------------
// Tool handlers
// ---------------------------------------------------------------------------
server.setRequestHandler(types_js_1.CallToolRequestSchema, async (request) => {
    const { name, arguments: args } = request.params;
    switch (name) {
        case "workspace_suggest": {
            const task = args?.task;
            const existing = listWorktreeNames();
            // Derive a candidate name from the task description
            const candidate = task
                .toLowerCase()
                .replace(/[^a-z0-9\s-]/g, "")
                .trim()
                .split(/\s+/)
                .slice(0, 4)
                .join("-");
            // Check for an existing workspace that might already cover this task
            const match = existing.find((n) => candidate.includes(n) || n.includes(candidate.split("-")[0]));
            if (match) {
                return {
                    content: [
                        {
                            type: "text",
                            text: JSON.stringify({
                                recommend: false,
                                reason: `Workspace "${match}" already exists and may cover this task.`,
                                existing_workspace: match,
                                worktree_path: worktreePath(match),
                                suggested_name: candidate,
                            }),
                        },
                    ],
                };
            }
            return {
                content: [
                    {
                        type: "text",
                        text: JSON.stringify({
                            recommend: true,
                            suggested_name: candidate,
                            reason: "No existing workspace found for this task.",
                        }),
                    },
                ],
            };
        }
        case "workspace_create": {
            const wsName = args?.name;
            const task = args?.task;
            // Run workspace.sh up (creates worktree, copies .env + .claude/)
            let upOutput;
            try {
                upOutput = runWorkspaceSh("up", wsName);
            }
            catch (e) {
                const msg = e instanceof Error ? e.message : String(e);
                return {
                    content: [{ type: "text", text: `workspace.sh up failed:\n${msg}` }],
                    isError: true,
                };
            }
            // Generate workspace CLAUDE.md and .workspace/ stubs
            try {
                runWorkspaceSh("context", wsName, task);
            }
            catch (e) {
                const msg = e instanceof Error ? e.message : String(e);
                return {
                    content: [
                        {
                            type: "text",
                            text: `workspace.sh up succeeded but context generation failed:\n${msg}\n\nUp output:\n${upOutput}`,
                        },
                    ],
                    isError: true,
                };
            }
            const wt = worktreePath(wsName);
            const branch = `${getBranchPrefix()}/${wsName}`;
            // Run project lifecycle scripts
            const cfg = resolveConfig();
            const lifecycleEnv = {
                WORKSPACE_PATH: wt,
                WORKSPACE_NAME: wsName,
                MAIN_CHECKOUT: getRepoRoot(),
            };
            const setupResult = runLifecycleScript("setup", cfg.workspace?.lifecycle?.setup, lifecycleEnv);
            const runResult = runLifecycleScript("run", cfg.workspace?.lifecycle?.run, lifecycleEnv);
            return {
                content: [
                    {
                        type: "text",
                        text: JSON.stringify({
                            success: true,
                            name: wsName,
                            worktree_path: wt,
                            branch,
                            lifecycle: {
                                setup: setupResult,
                                run: runResult,
                            },
                            artifacts: {
                                research: path.join(wt, ".workspace", "research.md"),
                                plan: path.join(wt, ".workspace", "plan.md"),
                            },
                            next_steps: [
                                "Populate .workspace/research.md and .workspace/plan.md via subagents",
                                `Then call workspace_open("${wsName}") to launch the worktree session`,
                            ],
                        }),
                    },
                ],
            };
        }
        case "workspace_open": {
            const wsName = args?.name;
            const wt = worktreePath(wsName);
            if (!worktreeExists(wsName)) {
                return {
                    content: [
                        {
                            type: "text",
                            text: `Workspace "${wsName}" does not exist. Create it first with workspace_create.`,
                        },
                    ],
                    isError: true,
                };
            }
            const cfg = resolveConfig();
            const claudeCmd = cfg.commands?.claude ?? "claude";
            const terminal = cfg.terminal ?? "";
            log(`open: platform=${process.platform}, terminal="${terminal}", command="${claudeCmd}"`);
            if (process.platform === "darwin" && terminal === "ghostty") {
                log(`open: using Ghostty AppleScript tab creation`);
                try {
                    (0, child_process_1.execSync)(`osascript -e '
            tell application "Ghostty"
              activate
              set cfgAS to new surface configuration
              set initial working directory of cfgAS to "${wt}"
              set command of cfgAS to "${claudeCmd}"
              set t to new tab in front window with configuration cfgAS
            end tell
          '`);
                    log(`open: Ghostty tab created successfully`);
                }
                catch (e) {
                    const msg = e instanceof Error ? e.message : String(e);
                    log(`open: Ghostty AppleScript failed (${msg}), falling back to detached spawn`);
                    const child = (0, child_process_1.spawn)(claudeCmd, [wt], {
                        detached: true,
                        stdio: "ignore",
                        shell: true,
                    });
                    child.unref();
                }
            }
            else {
                if (process.platform !== "darwin") {
                    log(`open: non-darwin platform, using detached spawn`);
                }
                else if (!terminal) {
                    log(`open: no terminal configured, using detached spawn`);
                }
                else {
                    log(`open: terminal "${terminal}" not supported for tab creation, using detached spawn`);
                }
                const child = (0, child_process_1.spawn)(claudeCmd, [wt], {
                    detached: true,
                    stdio: "ignore",
                    shell: true,
                });
                child.unref();
            }
            return {
                content: [
                    {
                        type: "text",
                        text: JSON.stringify({
                            success: true,
                            message: `Opening Claude Code session in ${wt}`,
                            worktree_path: wt,
                            terminal: terminal || "default",
                            claude_command: claudeCmd,
                        }),
                    },
                ],
            };
        }
        case "workspace_list": {
            const names = listWorktreeNames();
            if (names.length === 0) {
                return {
                    content: [
                        {
                            type: "text",
                            text: JSON.stringify({
                                workspaces: [],
                                message: "No workspaces found.",
                            }),
                        },
                    ],
                };
            }
            const workspaces = names.map((wsName) => {
                const wt = worktreePath(wsName);
                const branch = `${getBranchPrefix()}/${wsName}`;
                let lastCommit = "unknown";
                try {
                    lastCommit = run(`git log -1 --format='%h (%cr)' 2>/dev/null || echo unknown`, { cwd: wt });
                }
                catch {
                    /* ignore */
                }
                return {
                    name: wsName,
                    branch,
                    last_commit: lastCommit,
                    worktree_path: wt,
                };
            });
            return {
                content: [{ type: "text", text: JSON.stringify({ workspaces }) }],
            };
        }
        case "workspace_status": {
            const wsName = args?.name;
            const wt = worktreePath(wsName);
            const branch = `${getBranchPrefix()}/${wsName}`;
            const baseBranch = "main";
            if (!worktreeExists(wsName)) {
                return {
                    content: [
                        {
                            type: "text",
                            text: JSON.stringify({
                                error: `Workspace "${wsName}" not found.`,
                            }),
                        },
                    ],
                    isError: true,
                };
            }
            let ahead = "?", behind = "?", lastCommit = "unknown";
            try {
                ahead = run(`git rev-list ${baseBranch}..${branch} --count`, { cwd: wt });
                behind = run(`git rev-list ${branch}..${baseBranch} --count`, { cwd: wt });
                lastCommit = run(`git log -1 --format='%h %s (%cr)'`, { cwd: wt });
            }
            catch {
                /* ignore */
            }
            return {
                content: [
                    {
                        type: "text",
                        text: JSON.stringify({
                            name: wsName,
                            branch,
                            worktree_path: wt,
                            commits_ahead: ahead,
                            commits_behind: behind,
                            last_commit: lastCommit,
                        }),
                    },
                ],
            };
        }
        case "workspace_destroy": {
            const wsName = args?.name;
            const wt = worktreePath(wsName);
            // Run teardown lifecycle script before removing worktree
            const cfg = resolveConfig();
            const lifecycleEnv = {
                WORKSPACE_PATH: wt,
                WORKSPACE_NAME: wsName,
                MAIN_CHECKOUT: getRepoRoot(),
            };
            const teardownResult = runLifecycleScript("teardown", cfg.workspace?.lifecycle?.teardown, lifecycleEnv);
            try {
                const out = runWorkspaceSh("destroy", wsName);
                return {
                    content: [
                        {
                            type: "text",
                            text: JSON.stringify({
                                success: true,
                                output: out,
                                lifecycle: { teardown: teardownResult },
                            }),
                        },
                    ],
                };
            }
            catch (e) {
                const msg = e instanceof Error ? e.message : String(e);
                return {
                    content: [
                        { type: "text", text: `workspace_destroy failed:\n${msg}` },
                    ],
                    isError: true,
                };
            }
        }
        default:
            return {
                content: [{ type: "text", text: `Unknown tool: ${name}` }],
                isError: true,
            };
    }
});
// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------
async function main() {
    const transport = new stdio_js_1.StdioServerTransport();
    await server.connect(transport);
}
main().catch(console.error);
