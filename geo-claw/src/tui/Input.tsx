import React, { useEffect, useState } from 'react';
import { Box, Text, useInput } from 'ink';

const BLINK_MS = 600;

type Props = {
  disabled?: boolean;
  onSubmit: (text: string) => void;
};

export function Input({ disabled, onSubmit }: Props): React.ReactElement {
  const [buffer, setBuffer] = useState('');
  const [cursorOn, setCursorOn] = useState(true);

  useEffect(() => {
    const id = setInterval(() => {
      setCursorOn((v) => !v);
    }, BLINK_MS);
    return () => clearInterval(id);
  }, []);

  useInput(
    (input, key) => {
      if (disabled) return;
      if (key.return) {
        const trimmed = buffer.trim();
        if (trimmed.length === 0) return;
        setBuffer('');
        onSubmit(trimmed);
        return;
      }
      if (key.backspace || key.delete) {
        setBuffer((b) => b.slice(0, -1));
        return;
      }
      if (key.ctrl || key.meta) return;
      if (key.upArrow || key.downArrow || key.leftArrow || key.rightArrow) return;
      if (key.tab || key.escape) return;
      if (!input) return;
      setBuffer((b) => b + input);
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
