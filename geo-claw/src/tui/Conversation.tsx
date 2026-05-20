import React from 'react';
import { Box, Text, useStdout } from 'ink';

export type Role = 'you' | 'geo';

export type Message = {
  id: string;
  role: Role;
  text: string;
  timestamp?: Date;
  error?: boolean;
  dim?: boolean;
};

function formatTime(date: Date): string {
  const h = date.getHours().toString().padStart(2, '0');
  const m = date.getMinutes().toString().padStart(2, '0');
  return `${h}:${m}`;
}

type LineProps = { message: Message };

export function MessageLine({ message }: LineProps): React.ReactElement {
  const { stdout } = useStdout();
  const cols = stdout?.columns ?? 80;
  const ruleWidth = Math.max(Math.min(cols - 4, 64), 20);

  const prefixColor = message.role === 'geo' ? 'cyan' : undefined;
  const prefixText = message.role === 'geo' ? 'geo' : 'you';
  const bodyColor = message.error ? 'red' : undefined;
  const dim = message.dim === true;
  const timeStr = message.timestamp ? formatTime(message.timestamp) : '';

  return (
    <Box flexDirection="column" paddingX={2} paddingBottom={1}>
      <Box justifyContent="space-between" width={ruleWidth}>
        <Text color={prefixColor} dimColor={message.role === 'you' || dim} bold={message.role === 'geo' && !dim}>
          {prefixText}
        </Text>
        {timeStr ? <Text dimColor>{timeStr}</Text> : null}
      </Box>
      <Text color={bodyColor} dimColor={dim}>
        {message.text}
      </Text>
      <Box marginTop={1}>
        <Text dimColor>{'─'.repeat(ruleWidth)}</Text>
      </Box>
    </Box>
  );
}
