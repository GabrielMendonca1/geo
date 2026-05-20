#!/usr/bin/env node
import net from 'node:net';
import readline from 'node:readline';
import process from 'node:process';
import os from 'node:os';
import fs from 'node:fs';

const REQUIRED_ENV = ['GEO_HOST', 'GEO_PORT', 'GEO_AUTH_TOKEN', 'WORKER_NAME'];

function ts() {
  return new Date().toISOString();
}

function log(...args) {
  console.log(`[${ts()}]`, ...args);
}

function logErr(...args) {
  console.error(`[${ts()}]`, ...args);
}

function requireEnv() {
  const missing = REQUIRED_ENV.filter((k) => !process.env[k] || process.env[k].length === 0);
  if (missing.length > 0) {
    logErr(`missing required env vars: ${missing.join(', ')}`);
    process.exit(1);
  }
}

function detectSandbox() {
  const override = process.env.GEO_WORKER_I_KNOW_WHAT_IM_DOING === '1';
  if (override) return { sandboxed: true, reason: 'override' };
  if (fs.existsSync('/.dockerenv')) return { sandboxed: true, reason: 'docker' };
  if (fs.existsSync('/run/.containerenv')) return { sandboxed: true, reason: 'podman' };
  return { sandboxed: false, reason: 'none' };
}

function preflight() {
  const sandbox = detectSandbox();
  const uid = typeof process.getuid === 'function' ? process.getuid() : -1;
  const override = process.env.GEO_WORKER_I_KNOW_WHAT_IM_DOING === '1';
  if (!sandbox.sandboxed && uid === 0 && !override) {
    logErr('refusing to run as root outside a sandbox. set GEO_WORKER_I_KNOW_WHAT_IM_DOING=1 to override.');
    process.exit(1);
  }
  log(`preflight ok host=${os.hostname()} uid=${uid} sandbox=${sandbox.reason}`);
}

function parseRepos() {
  const raw = process.env.WORKER_REPOS || '';
  return raw.split(',').map((s) => s.trim()).filter((s) => s.length > 0);
}

function buildInitialize() {
  return {
    jsonrpc: '2.0',
    id: 1,
    method: 'initialize',
    params: {
      authToken: process.env.GEO_AUTH_TOKEN,
      workerName: process.env.WORKER_NAME,
      capabilities: {
        repos: parseRepos(),
        runtime: 'claude-code'
      }
    }
  };
}

function send(socket, obj) {
  const line = JSON.stringify(obj) + '\n';
  socket.write(line);
}

function respond(socket, id, result) {
  send(socket, { jsonrpc: '2.0', id, result });
}

function respondError(socket, id, code, message) {
  send(socket, { jsonrpc: '2.0', id, error: { code, message } });
}

function notify(socket, method, params) {
  send(socket, { jsonrpc: '2.0', method, params });
}

function handleDispatchRun(socket, msg) {
  const id = msg.id;
  const dispatchId = String(id);
  log(`dispatch.run id=${dispatchId} params=${JSON.stringify(msg.params || {})}`);
  respond(socket, id, { acknowledged: true, dispatchId });
  setTimeout(() => {
    notify(socket, 'dispatch.progress', {
      dispatchId,
      stage: 'running',
      message: 'claude session starting (stub)'
    });
  }, 1000);
  setTimeout(() => {
    notify(socket, 'dispatch.complete', {
      dispatchId,
      success: true,
      exitCode: 0,
      summary: 'mock dispatch complete',
      artifacts: []
    });
  }, 2000);
}

function handleDispatchCancel(socket, msg) {
  log(`dispatch.cancel id=${msg.id}`);
  respond(socket, msg.id, { cancelled: true });
}

function handleMessage(socket, msg) {
  if (!msg || typeof msg !== 'object') return;
  const { method, id } = msg;
  if (!method) {
    log(`recv response id=${id}`);
    return;
  }
  switch (method) {
    case 'dispatch.run':
      handleDispatchRun(socket, msg);
      break;
    case 'dispatch.cancel':
      handleDispatchCancel(socket, msg);
      break;
    default:
      if (id !== undefined && id !== null) {
        respondError(socket, id, -32601, 'Method not found');
      } else {
        log(`ignoring unknown notification method=${method}`);
      }
  }
}

function connectAndRun() {
  const host = process.env.GEO_HOST;
  const port = Number(process.env.GEO_PORT);
  log(`connecting host=${host} port=${port} worker=${process.env.WORKER_NAME}`);
  const socket = net.createConnection({ host, port });
  const rl = readline.createInterface({ input: socket, crlfDelay: Infinity });
  let initialized = false;

  socket.on('connect', () => {
    log('tcp connected, sending initialize');
    send(socket, buildInitialize());
  });

  rl.on('line', (line) => {
    if (line.length === 0) return;
    let msg;
    try {
      msg = JSON.parse(line);
    } catch (err) {
      logErr(`parse error: ${err.message} line=${line.slice(0, 200)}`);
      return;
    }
    if (!initialized) {
      if (msg.id === 1 && msg.result) {
        initialized = true;
        log(`initialize ok session=${JSON.stringify(msg.result)}`);
        return;
      }
      if (msg.id === 1 && msg.error) {
        logErr(`initialize failed: ${JSON.stringify(msg.error)}`);
        socket.destroy();
        process.exit(1);
      }
      return;
    }
    handleMessage(socket, msg);
  });

  socket.on('error', (err) => {
    logErr(`socket error: ${err.message}`);
  });

  socket.on('close', () => {
    log('socket closed, exiting');
    process.exit(initialized ? 0 : 1);
  });

  const shutdown = (sig) => {
    log(`received ${sig}, shutting down`);
    try {
      socket.end();
      socket.destroy();
    } catch {}
    process.exit(0);
  };
  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));
}

function main() {
  requireEnv();
  preflight();
  const claudeCmd = process.env.CLAUDE_CMD || 'claude';
  const safeMode = (process.env.SAFE_MODE || 'false').toLowerCase() === 'true';
  log(`config claude_cmd=${claudeCmd} safe_mode=${safeMode}`);
  connectAndRun();
}

try {
  main();
} catch (err) {
  logErr(`fatal: ${err && err.stack ? err.stack : err}`);
  process.exit(1);
}
