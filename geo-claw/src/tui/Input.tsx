import React, { useRef, useState } from 'react';
import { Box, Text, useInput } from 'ink';
import { COLORS, GLYPHS } from './theme.js';

type Props = {
  disabled?: boolean;
  onSubmit: (text: string) => void;
  history: string[];
};

function deleteWordBack(buffer: string, cursor: number): { buffer: string; cursor: number } {
  if (cursor === 0) return { buffer, cursor };
  let i = cursor;
  while (i > 0 && /\s/.test(buffer[i - 1] ?? '')) i--;
  while (i > 0 && !/\s/.test(buffer[i - 1] ?? '')) i--;
  return { buffer: buffer.slice(0, i) + buffer.slice(cursor), cursor: i };
}

export function Input({ disabled, onSubmit, history }: Props): React.ReactElement {
  const [buffer, setBuffer] = useState('');
  const [cursor, setCursor] = useState(0);
  const historyIndexRef = useRef<number>(-1);
  const draftRef = useRef<string>('');

  const replaceBuffer = (next: string): void => {
    setBuffer(next);
    setCursor(next.length);
  };

  useInput(
    (input, key) => {
      if (disabled) return;

      if (key.upArrow) {
        if (history.length === 0) return;
        if (historyIndexRef.current === -1) draftRef.current = buffer;
        const next = Math.min(historyIndexRef.current + 1, history.length - 1);
        historyIndexRef.current = next;
        const item = history[history.length - 1 - next];
        if (typeof item === 'string') replaceBuffer(item);
        return;
      }
      if (key.downArrow) {
        if (historyIndexRef.current <= 0) {
          historyIndexRef.current = -1;
          replaceBuffer(draftRef.current);
          return;
        }
        const next = historyIndexRef.current - 1;
        historyIndexRef.current = next;
        const item = history[history.length - 1 - next];
        if (typeof item === 'string') replaceBuffer(item);
        return;
      }

      if (key.leftArrow) {
        setCursor((c) => Math.max(0, c - 1));
        return;
      }
      if (key.rightArrow) {
        setCursor((c) => Math.min(buffer.length, c + 1));
        return;
      }

      if (key.backspace) {
        if (cursor === 0) return;
        setBuffer((b) => b.slice(0, cursor - 1) + b.slice(cursor));
        setCursor((c) => Math.max(0, c - 1));
        historyIndexRef.current = -1;
        return;
      }
      if (key.delete) {
        if (cursor >= buffer.length) return;
        setBuffer((b) => b.slice(0, cursor) + b.slice(cursor + 1));
        historyIndexRef.current = -1;
        return;
      }

      if (key.return) {
        if (input && input.length > 0 && input !== '\r' && input !== '\n') {
          const insert = input.replace(/\r/g, '\n');
          setBuffer((b) => b.slice(0, cursor) + insert + b.slice(cursor));
          setCursor((c) => c + insert.length);
          historyIndexRef.current = -1;
          return;
        }
        const trimmed = buffer.trim();
        if (trimmed.length === 0) return;
        setBuffer('');
        setCursor(0);
        historyIndexRef.current = -1;
        draftRef.current = '';
        onSubmit(trimmed);
        return;
      }

      if (key.ctrl) return;
      if (key.escape) return;
      if (key.tab) return;
      if (!input) return;

      setBuffer((b) => b.slice(0, cursor) + input + b.slice(cursor));
      setCursor((c) => c + input.length);
      historyIndexRef.current = -1;
    },
    { isActive: process.stdin.isTTY === true },
  );

  const borderColor = disabled ? COLORS.dim : COLORS.accent;
  const promptColor = disabled ? COLORS.dim : COLORS.accent;
  const before = buffer.slice(0, cursor);
  const at = cursor < buffer.length ? buffer[cursor] ?? ' ' : ' ';
  const after = cursor < buffer.length ? buffer.slice(cursor + 1) : '';

  return (
    <Box borderStyle="round" borderColor={borderColor} paddingX={1} marginX={1}>
      <Text color={promptColor} bold>
        {GLYPHS.prompt}{' '}
      </Text>
      <Text>{before}</Text>
      <Text inverse>{at}</Text>
      <Text>{after}</Text>
    </Box>
  );
}
