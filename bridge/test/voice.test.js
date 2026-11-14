import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { Voice } from '../src/voice.js';

test('a custom speech command gets the text on its standard input, through the shell of the system it runs on', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 't3wow-voice-'));
  const heard = path.join(dir, 'heard.txt');
  const say = path.join(dir, 'say.cjs');
  fs.writeFileSync(say, "let text = ''; process.stdin.on('data', (d) => (text += d)).on('end', () => require('node:fs').writeFileSync(process.argv[2], text));");
  const voice = new Voice({ ttsCommand: `"${process.execPath}" "${say}" "${heard}"` });
  assert.equal(voice.speak('Für Elise, twice'), true);
  await new Promise((resolve) => voice.current.once('exit', resolve));
  assert.equal(fs.readFileSync(heard, 'utf8'), 'Für Elise, twice');
});

/** A stand-in voice that takes `ms` to say whatever arrives on its standard input. */
function slowVoice(dir, ms) {
  const say = path.join(dir, 'slow.cjs');
  fs.writeFileSync(say, `process.stdin.resume().on('end', () => setTimeout(() => {}, ${ms}));`);
  return `"${process.execPath}" "${say}"`;
}

test('a reading is speaking until its program exits or a hush stops it, and each change is reported once', async (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 't3wow-voice-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const changes = [];
  const voice = new Voice({ ttsCommand: slowVoice(dir, 300), onSpeaking: (on) => changes.push(on) });
  assert.equal(voice.speaking, false);
  voice.speak('One');
  assert.equal(voice.speaking, true);
  await new Promise((resolve) => voice.current.once('exit', resolve));
  assert.equal(voice.speaking, false, 'done once the program exits');
  voice.speak('Two');
  voice.speak('Three');
  assert.equal(voice.speaking, true, 'the next reading cuts the last one off and goes on');
  voice.hush();
  assert.equal(voice.speaking, false, 'a hush stops it at once');
  voice.hush();
  assert.deepEqual(changes, [true, false, true, false]);
});
