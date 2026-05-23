import React, { useMemo } from 'react';
import { Text } from 'ink';
import { marked } from 'marked';
import { markedTerminal } from 'marked-terminal';

let configured = false;
function ensureConfigured(): void {
  if (configured) return;
  marked.use(
    markedTerminal({
      width: 80,
      reflowText: false,
      tab: 2,
      unescape: true,
    }) as Parameters<typeof marked.use>[0],
  );
  configured = true;
}

export function Markdown({ text }: { text: string }): React.ReactElement {
  const rendered = useMemo(() => {
    ensureConfigured();
    try {
      const out = marked.parse(text) as string;
      return out.replace(/\n+$/, '');
    } catch {
      return text;
    }
  }, [text]);

  return <Text>{rendered}</Text>;
}
