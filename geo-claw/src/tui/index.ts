import React from 'react';
import { render } from 'ink';
import { App } from './App.js';

export async function startTui(opts: {
  runTurn: (text: string) => Promise<string>;
  statusFilePath: string;
}): Promise<void> {
  process.stdout.write('\x1b]0;geo\x07');
  process.stdout.write('\x1b[2J\x1b[3J\x1b[H');
  process.stdout.write('\n  \x1b[36mgeo\x1b[0m\n\n');
  const instance = render(
    React.createElement(App, {
      runTurn: opts.runTurn,
      statusFilePath: opts.statusFilePath,
    }),
  );
  await instance.waitUntilExit();
}
