import React from 'react';
import { Box, Text } from 'ink';

export type Role = 'you' | 'geo';

export type Message = {
  id: string;
  role: Role;
  text: string;
  error?: boolean;
  dim?: boolean;
};

type LineProps = { message: Message };

export function MessageLine({ message }: LineProps): React.ReactElement {
  const prefixColor = message.role === 'geo' ? 'cyan' : undefined;
  const prefixText = message.role === 'geo' ? 'geo' : 'you';
  const bodyColor = message.error ? 'red' : undefined;
  const dim = message.dim === true;

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
