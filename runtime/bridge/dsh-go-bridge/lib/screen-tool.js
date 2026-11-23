// look_at_screen: a local tool that returns the phone's latest screen frame as
// an image, so the model can decide on its own when it needs to look — asked
// "what's on my screen", or watching something disappear — instead of the app
// guessing from keywords. Frames are written by the app (screencap plugin →
// external files dir) about once a second while screen sharing is on.
import { readFileSync, statSync } from 'node:fs';

const CANDIDATES = [
  process.env.DSH_SCREEN_FRAME,
  // The parallel test build and the official package both write here.
  '/sdcard/Android/data/io.github.ccch1mneyyy.dsh_app.screenshare/files/screen/latest.jpg',
  '/sdcard/Android/data/io.github.ccch1mneyyy.dsh_app/files/screen/latest.jpg',
  '/sdcard/Download/DSH-Go/screen-frames/latest.jpg',
].filter(value => typeof value === 'string' && value.length > 0);

function latest() {
  let best = null;
  const tried = [];
  for (const path of CANDIDATES) {
    try {
      const stat = statSync(path);
      if (!stat.isFile() || stat.size === 0) { tried.push(`${path}: empty`); continue; }
      if (!best || stat.mtimeMs > best.mtimeMs) best = { path, mtimeMs: stat.mtimeMs, size: stat.size };
    } catch (error) {
      tried.push(`${path}: ${error && error.code ? error.code : 'missing'}`);
    }
  }
  return { best, tried };
}

/** Registers the tool; returns its disposer. */
export function registerScreenTool(ctx) {
  return ctx.tools.register({
    name: 'look_at_screen',
    description:
      '查看手机当前屏幕：返回最新的一张屏幕截图（图片）。当用户让你看屏幕、问屏幕上的内容，'
      + '或让你盯着屏幕上的某样东西时调用。要持续观察时，可以隔几秒重复调用本工具（或用 bash 的 sleep 控制间隔）。'
      + '这个工具只依赖用户开启的“屏幕共享”，不需要手机操控/无障碍权限；不要改用手机操控里的 screen 工具。'
      + '如果用户还没开启屏幕共享，会返回没有画面的说明。',
    parameters: {
      type: 'object',
      properties: {
        note: { type: 'string', description: '可选：你想在画面里重点看什么' },
      },
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
      const { best: frame, tried } = latest();
      if (!frame) {
        return { text: '现在没有可用的屏幕画面：用户还没有开启屏幕共享，或者画面还没传过来。检查过：' + tried.join('; ') };
      }
      let bytes;
      try {
        bytes = readFileSync(frame.path);
      } catch (error) {
        return { text: `找到画面文件但读不了：${frame.path}（${error && error.code ? error.code : error}）` };
      }
      const age = Math.max(0, Math.round((Date.now() - frame.mtimeMs) / 1000));
      return {
        text: `这是手机当前屏幕的最新画面（约 ${age} 秒前）。`,
        data: bytes.toString('base64'),
        mimeType: 'image/jpeg',
      };
    },
  });
}
