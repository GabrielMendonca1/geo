import React, { useEffect, useState } from 'react';
import { Box, Text } from 'ink';
import { ThinkingDot } from './ThinkingDot.js';

export type Role = 'you' | 'geo';

export type Message = {
  id: string;
  role: Role;
  text: string;
  error?: boolean;
  dim?: boolean;
};

const FADE_MS = 120;

type LineProps = { message: Message };

function MessageLine({ message }: LineProps): React.ReactElement {
  const [faded, setFaded] = useState(true);

  useEffect(() => {
    const t = setTimeout(() => setFaded(false), FADE_MS);
    return () => clearTimeout(t);
  }, []);

  const prefixColor = message.role === 'geo' ? 'cyan' : undefined;
  const prefixText = message.role === 'geo' ? 'geo' : 'you';
  const bodyColor = message.error ? 'red' : undefined;
  const dim = message.dim === true || faded;

  return (
    <Box flexDirection="column" paddingX={2} paddingBottom={1}>
      <Text color={prefixColor} dimColor={message.role === 'you' || dim}>
        {prefixText}
      </Text>
      <Text color={bodyColor} dimColor={dim}>
        {message.text}
      </Text>
    </Box>
  );
}

type Props = {
  messages: Message[];
  inflight: boolean;
};

export function Conversation({ messages, inflight }: Props): React.ReactElement {
  return (
    <Box flexDirection="column" flexGrow={1}>
      {messages.map((m) => (
        <MessageLine key={m.id} message={m} />
      ))}
      {inflight ? <ThinkingDot /> : null}
    </Box>
  );
}
