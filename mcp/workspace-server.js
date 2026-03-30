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
// ---------------------------------------------------------------------------
// Config — derived from the location of this script, mirroring workspace.sh
// ---------------------------------------------------------------------------
const MAIN_CHECKOUT = path.resolve(__dirname, "..");
const WORKSPACE_SH = path.join(MAIN_CHECKOUT, "workspace.sh");
function getWorktreeRoot() {
    return path.join(path.dirname(MAIN_CHECKOUT), "next-chief-of-staff-worktrees");
}
function getBranchPrefix() {
    try {
        const name = (0, child_process_1.execSync)("git config user.name", { cwd: MAIN_CHECKOUT })
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
        cwd: opts.cwd ?? MAIN_CHECKOUT,
        encoding: "utf8",
    }).trim();
}
function runWorkspaceSh(...args) {
    return run(`bash "${WORKSPACE_SH}" ${args.map((a) => `"${a}"`).join(" ")}`);
}
function isStackRunning(projectName) {
    try {
        const out = (0, child_process_1.execSync)(`docker compose -p "${projectName}" ps --status running 2>/dev/null`, { encoding: "utf8" });
        return out
            .split("\n")
            .slice(1)
            .some((l) => l.trim().length > 0);
    }
    catch {
        return false;
    }
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
            if (m && m[1] !== MAIN_CHECKOUT && m[1].startsWith(worktreeRoot)) {
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
const server = new index_js_1.Server({ name: "workspace", version: "1.0.0" }, { capabilities: { tools: {} } });
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
                "(2) a running stack — the work requires Docker services to develop or test; " +
                "(3) its own branch — the change is going somewhere independently from dev. " +
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
            description: "Creates an isolated workspace for a task: git worktree on a new branch, Docker Compose stack with Traefik routing, " +
                "and a workspace-specific CLAUDE.md with task context. Also creates .workspace/research.md and .workspace/plan.md as " +
                "artifact stubs for the research subagent to populate. " +
                "Use after workspace_suggest confirms a workspace is warranted. " +
                "Returns the worktree path and service URLs once the stack is healthy.",
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
            description: "Lists all workspaces with their status, branch, Docker state, and URLs. " +
                "Use to check what workspaces exist before creating a new one, or to get an overview of active work.",
            inputSchema: {
                type: "object",
                properties: {},
            },
        },
        {
            name: "workspace_status",
            description: "Returns detailed status for a single workspace: branch, commits ahead/behind, Docker health, and service URLs. " +
                "Use when you need to know if a workspace's stack is running before doing work inside it.",
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
            description: "Stops the Docker stack and removes the worktree and branch for a workspace. " +
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
            // Run workspace.sh up (creates worktree, starts Docker, installs deps, copies .env + .claude)
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
            return {
                content: [
                    {
                        type: "text",
                        text: JSON.stringify({
                            success: true,
                            name: wsName,
                            worktree_path: wt,
                            branch,
                            frontend_url: `http://cos-${wsName}.lvh.me`,
                            api_url: `http://api-cos-${wsName}.lvh.me`,
                            phoenix_url: `http://phoenix-cos-${wsName}.lvh.me`,
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
            // Shell out to open a new Claude Code session in the worktree directory
            const child = (0, child_process_1.spawn)("claude", [wt], {
                detached: true,
                stdio: "ignore",
                shell: true,
            });
            child.unref();
            return {
                content: [
                    {
                        type: "text",
                        text: JSON.stringify({
                            success: true,
                            message: `Opening Claude Code session in ${wt}`,
                            worktree_path: wt,
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
                const project = `cos-${wsName}`;
                const wt = worktreePath(wsName);
                const branch = `${getBranchPrefix()}/${wsName}`;
                const running = isStackRunning(project);
                let lastCommit = "unknown";
                try {
                    lastCommit = run(`git log -1 --format='%h (%cr)' 2>/dev/null || echo unknown`, {
                        cwd: wt,
                    });
                }
                catch {
                    /* ignore */
                }
                return {
                    name: wsName,
                    branch,
                    last_commit: lastCommit,
                    docker: running ? "running" : "stopped",
                    ...(running
                        ? {
                            frontend_url: `http://cos-${wsName}.lvh.me`,
                            api_url: `http://api-cos-${wsName}.lvh.me`,
                            phoenix_url: `http://phoenix-cos-${wsName}.lvh.me`,
                        }
                        : {}),
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
            const project = `cos-${wsName}`;
            const branch = `${getBranchPrefix()}/${wsName}`;
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
                ahead = run(`git rev-list dev..${branch} --count`, { cwd: wt });
                behind = run(`git rev-list ${branch}..dev --count`, { cwd: wt });
                lastCommit = run(`git log -1 --format='%h %s (%cr)'`, { cwd: wt });
            }
            catch {
                /* ignore */
            }
            const running = isStackRunning(project);
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
                            docker: running ? "running" : "stopped",
                            ...(running
                                ? {
                                    frontend_url: `http://cos-${wsName}.lvh.me`,
                                    api_url: `http://api-cos-${wsName}.lvh.me`,
                                    phoenix_url: `http://phoenix-cos-${wsName}.lvh.me`,
                                }
                                : {}),
                        }),
                    },
                ],
            };
        }
        case "workspace_destroy": {
            const wsName = args?.name;
            try {
                const out = runWorkspaceSh("destroy", wsName);
                return {
                    content: [
                        {
                            type: "text",
                            text: JSON.stringify({ success: true, output: out }),
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
