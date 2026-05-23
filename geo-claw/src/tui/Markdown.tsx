import React, { useMemo } from 'react';
import { Text } from 'ink';
import { marked } from 'marked';
import { markedTerminal } from 'marked-terminal';
import chalk from 'chalk';
import { COLORS } from './theme.js';

const accent = chalk.hex(COLORS.accent).bold;
const accentDim = chalk.hex(COLORS.accentDim).bold;
const codeColor = chalk.hex('#a0c4ff');
const linkColor = chalk.hex('#7da6ff').underline;
const blockquoteColor = chalk.hex('#6a6a6a').italic;

let configured = false;
function ensureConfigured(): void {
  if (configured) return;
  marked.use(
    markedTerminal({
      width: 80,
      reflowText: false,
      tab: 2,
      unescape: true,
      firstHeading: accent,
      heading: accentDim,
      code: codeColor,
      codespan: codeColor,
      link: linkColor,
      href: linkColor,
      blockquote: blockquoteColor,
      strong: chalk.bold,
      em: chalk.italic,
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
