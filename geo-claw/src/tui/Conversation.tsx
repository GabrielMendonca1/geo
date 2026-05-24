import React from 'react';
import { Box, Text } from 'ink';
import { COLORS, GLYPHS } from './theme.js';
import { Markdown } from './Markdown.js';

export type Role = 'you' | 'geo';

export type Message = {
  id: string;
  role: Role;
  text: string;
  timestamp?: Date;
  error?: boolean;
  dim?: boolean;
};

function MessageLineImpl({ message }: { message: Message }): React.ReactElement {
  const isGeo = message.role === 'geo';
  const glyph = isGeo ? GLYPHS.geo : GLYPHS.user;
  const glyphColor = message.error
    ? COLORS.err
    : isGeo
      ? COLORS.geo
      : COLORS.user;

  const renderBody = (): React.ReactElement => {
    if (isGeo && !message.error && !message.dim) {
      return <Markdown text={message.text} />;
    }
    return (
      <Text
        color={message.error ? COLORS.err : undefined}
        dimColor={message.dim === true}
      >
        {message.text}
      </Text>
    );
  };

  return (
    <Box flexDirection="row" paddingX={2} marginBottom={1}>
      <Text color={glyphColor} bold={isGeo}>
        {glyph}{' '}
      </Text>
      <Box flexDirection="column" flexGrow={1}>
        {renderBody()}
      </Box>
    </Box>
  );
}

export const MessageLine = React.memo(MessageLineImpl, (prev, next) => prev.message === next.message);
