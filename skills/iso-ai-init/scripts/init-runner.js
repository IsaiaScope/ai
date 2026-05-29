#!/usr/bin/env node
"use strict";

const { existsSync, readFileSync } = require("fs");
const { dirname, isAbsolute, join, resolve } = require("path");
const { spawnSync } = require("child_process");

const skillBase = resolve(process.env.ISO_AI_INIT_BASE || join(__dirname, ".."));
const manifestPath = process.env.ISO_AI_INIT_MANIFEST || join(skillBase, "steps.json");

function inGitRepo() {
  if (process.env.ISO_AI_INIT_IN_GIT_REPO === "true") return true;
  if (process.env.ISO_AI_INIT_IN_GIT_REPO === "false") return false;
  const r = spawnSync("git", ["rev-parse", "--is-inside-work-tree"], { stdio: "ignore" });
  return r.status === 0;
}

function resolveArg(arg) {
  if (typeof arg !== "string") return arg;
  if (isAbsolute(arg)) return arg;
  if (!arg.includes("/")) return arg;
  const candidate = join(skillBase, arg);
  return existsSync(candidate) ? candidate : arg;
}

function stepCommand(step) {
  if (!Array.isArray(step.command) || step.command.length === 0) {
    throw new Error(`step ${step.id} has no command array`);
  }
  const [cmd, ...args] = step.command;
  return [cmd, ...args.map(resolveArg)];
}

function main() {
  const repo = inGitRepo();
  const steps = JSON.parse(readFileSync(manifestPath, "utf8"));
  const summary = [];

  for (const step of steps) {
    if (step.enabled === false) {
      summary.push(`skip ${step.id} (disabled)`);
      continue;
    }
    if (step.scope === "repo" && !repo) {
      summary.push(`skip ${step.id} (not a git repo)`);
      continue;
    }
    const [cmd, ...args] = stepCommand(step);
    console.log(`run ${step.id} [${step.scope || "global"}]`);
    const r = spawnSync(cmd, args, { cwd: process.cwd(), stdio: "inherit", env: process.env });
    if (r.status !== 0) {
      console.error(`fail ${step.id} (exit ${r.status})`);
      process.exit(r.status || 1);
    }
    summary.push(`ok ${step.id}`);
  }

  console.log("--- iso-ai-init summary ---");
  for (const line of summary) console.log(line);
}

main();
