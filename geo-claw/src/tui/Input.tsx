import React, { useEffect, useRef, useState } from 'react';
import { Box, Text, useInput } from 'ink';

const BLINK_MS = 600;

type Props = {
  disabled?: boolean;
  onSubmit: (text: string) => void;
  history: string[];
};

export function Input({ disabled, onSubmit, history }: Props): React.ReactElement {
  const [buffer, setBuffer] = useState('');
  const [cursorOn, setCursorOn] = useState(true);
  const historyIndexRef = useRef<number>(-1);

  useEffect(() => {
    const id = setInterval(() => {
      setCursorOn((v) => !v);
    }, BLINK_MS);
    return () => clearInterval(id);
  }, []);

  useInput(
    (input, key) => {
      if (disabled) return;

      if (key.upArrow) {
        if (history.length === 0) return;
        const next = Math.min(historyIndexRef.current + 1, history.length - 1);
        historyIndexRef.current = next;
        setBuffer(history[history.length - 1 - next]);
        return;
      }
      if (key.downArrow) {
        if (historyIndexRef.current <= 0) {
          historyIndexRef.current = -1;
          setBuffer('');
          return;
        }
        const next = historyIndexRef.current - 1;
        historyIndexRef.current = next;
        setBuffer(history[history.length - 1 - next]);
        return;
      }

      if (key.return) {
        const trimmed = buffer.trim();
        if (trimmed.length === 0) return;
        setBuffer('');
        historyIndexRef.current = -1;
        onSubmit(trimmed);
        return;
      }
      if (key.backspace || key.delete) {
        setBuffer((b) => b.slice(0, -1));
        historyIndexRef.current = -1;
        return;
      }
      if (key.ctrl || key.meta) return;
      if (key.leftArrow || key.rightArrow) return;
      if (key.tab || key.escape) return;
      if (!input) return;
      setBuffer((b) => b + input);
      historyIndexRef.current = -1;
    },
    { isActive: process.stdin.isTTY === true },
  );

  return (
    <Box paddingX={2} paddingY={1}>
      <Text dimColor>› </Text>
      <Text>{buffer}</Text>
      <Text dimColor={!cursorOn}>{cursorOn ? '▏' : ' '}</Text>
    </Box>
  );
}
