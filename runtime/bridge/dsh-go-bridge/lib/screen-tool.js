// 通话里的画面: tools for what the phone shares during a voice call (the screen or
// the camera). The app writes, under DSH home (guest rootfs, so no shared-storage
// permission is involved):
//   dsh-go/vision/latest.jpg   the newest kept frame
//   dsh-go/vision/status.json  { sharing, source: "screen"|"camera"|null, judge, updatedAt }
//
// look_at_screen returns the newest frame as an image. watch_screen and
// stop_watching_screen only check and acknowledge here: the app sees the tool
// call in the call's conversation and does the watching itself (its own frames,
// a vision model to judge them, and the call's voice for the reminder).
import { readFileSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

/** A frame older than this is "not coming in" (sharing stopped, app killed). */
const STALE_MS = 30_000;

function visionDir() {
  const home = process.env.DSH_HOME || join(homedir(), '.dsh');
  return join(home, 'dsh-go', 'vision');
}

function readStatus(dir) {
  try {
    const status = JSON.parse(readFileSync(join(dir, 'status.json'), 'utf8'));
    return status && typeof status === 'object' ? status : null;
  } catch {
    return null;
  }
}

function sourceName(source) {
  return source === 'camera' ? '摄像头' : '屏幕';
}

/** What the app shares now: { live, source, judge, path, age } or { live: false, why }. */
function current() {
  const dir = visionDir();
  const status = readStatus(dir);
  const path = join(dir, 'latest.jpg');
  let stat = null;
  try {
    stat = statSync(path);
    if (!stat.isFile() || stat.size === 0) stat = null;
  } catch {}
  const updated = Number(status?.updatedAt) || 0;
  const fresh = Date.now() - Math.max(updated, stat?.mtimeMs ?? 0) < STALE_MS;
  if (!status?.sharing || !stat || !fresh) {
    return { live: false, why: '用户现在没有在通话里共享屏幕或打开摄像头（或者画面还没传过来）。' };
  }
  return {
    live: true,
    source: status.source === 'camera' ? 'camera' : 'screen',
    judge: status.judge === true,
    path,
    age: Math.max(0, Math.round((Date.now() - stat.mtimeMs) / 1000)),
  };
}

function textOutput() {
  return {
    schema: { type: 'object', properties: { text: { type: 'string' } }, required: ['text'] },
    render: (_args, value) => [{ type: 'text', text: value.text }],
  };
}

/** Registers the tools; returns one disposer for all of them. */
export function registerScreenTool(ctx) {
  const disposers = [];
  disposers.push(ctx.tools.register({
    name: 'look_at_screen',
    description:
      '看用户在语音通话里共享的画面（手机屏幕，或用户打开的摄像头），返回最新的一张图片。'
      + '用户让你看看、问画面里有什么时调用。只依赖通话里的共享，不需要手机操控/无障碍；不要改用手机操控里的 screen 工具。'
      + '要持续盯着某个变化时，不要反复调用本工具，改用 watch_screen。',
    parameters: {
      type: 'object',
      properties: { note: { type: 'string', description: '可选：你想在画面里重点看什么' } },
      additionalProperties: false,
    },
    timeoutMs: 15000,
    output: {
      schema: {
        type: 'object',
        properties: { text: { type: 'string' }, data: { type: 'string' }, mimeType: { type: 'string' } },
        required: ['text'],
      },
      render: (_args, value) => [
        { type: 'text', text: value.text },
        ...(value.data && value.mimeType ? [{ type: 'image', data: value.data, mimeType: value.mimeType }] : []),
      ],
    },
    async execute() {
      const now = current();
      if (!now.live) return { text: now.why };
      let bytes;
      try {
        bytes = readFileSync(now.path);
      } catch (error) {
        return { text: `画面文件读不了（${error && error.code ? error.code : 'error'}）。` };
      }
      return {
        text: `这是用户${sourceName(now.source)}的最新画面（约 ${now.age} 秒前）。`,
        data: bytes.toString('base64'),
        mimeType: 'image/jpeg',
      };
    },
  }));
  disposers.push(ctx.tools.register({
    name: 'watch_screen',
    description:
      '在语音通话里替用户盯着共享的画面（屏幕或摄像头），等某个情况出现时在通话里主动提醒用户。'
      + '用户说“帮我盯着…/…了叫我/看到…告诉我”时调用。condition 写成一句可以直接看图判断的条件，'
      + '把对话里相关的上下文写进去（例如“下载进度条走完或者出现报错弹窗”，而不是“那个好了”）。'
      + '调用后由手机持续看画面，满足时会用一句话提醒用户；你不需要再反复查看。同一时间只盯一件事，新的会替换旧的。',
    parameters: {
      type: 'object',
      properties: {
        condition: { type: 'string', description: '要等待出现的情况，一句能看图判断的话' },
        remind: { type: 'string', description: '可选：满足时想对用户说的话的要点' },
        minutes: { type: 'number', description: '可选：最多盯多少分钟，默认 30' },
      },
      required: ['condition'],
      additionalProperties: false,
    },
    timeoutMs: 5000,
    output: textOutput(),
    async execute(args) {
      const condition = typeof args?.condition === 'string' ? args.condition.trim() : '';
      if (!condition) return { text: '没有给出要盯的条件。' };
      const now = current();
      if (!now.live) return { text: `${now.why}请用户先在通话里点“共享屏幕”或“摄像头”，再让你盯。` };
      if (!now.judge) {
        return { text: '手机上还没有配置看图模型（设置 → 语音 → 通话 → 看图模型），盯不了；请告诉用户先去配置。' };
      }
      return { text: `好的，手机开始盯着${sourceName(now.source)}：${condition}。满足时会在通话里提醒用户。` };
    },
  }));
  disposers.push(ctx.tools.register({
    name: 'stop_watching_screen',
    description: '停止 watch_screen 正在盯的事。用户说不用盯了、或者事情已经办完时调用。',
    parameters: { type: 'object', properties: {}, additionalProperties: false },
    timeoutMs: 5000,
    output: textOutput(),
    async execute() {
      return { text: '已停止盯画面。' };
    },
  }));
  return () => {
    for (const dispose of disposers.reverse()) {
      try { dispose?.(); } catch {}
    }
  };
}
