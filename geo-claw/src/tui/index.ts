import React from 'react';
import { render } from 'ink';
import { App } from './App.js';

export async function startTui(opts: {
  runTurn: (text: string) => Promise<string>;
  statusFilePath: string;
}): Promise<void> {
  const instance = render(
    React.createElement(App, {
      runTurn: opts.runTurn,
      statusFilePath: opts.statusFilePath,
    }),
  );
  await instance.waitUntilExit();
}
