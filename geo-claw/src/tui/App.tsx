import React, { useCallback, useEffect, useRef, useState } from 'react';
import { Box, Static, Text, useApp, useInput, useStdout } from 'ink';
import { Header } from './Header.js';
import { MessageLine, type Message } from './Conversation.js';
import { GeoSpinner } from './Spinner.js';
import { Input } from './Input.js';
import { useStatusFile } from './useStatusFile.js';
import { COLORS, GLYPHS } from './theme.js';

type Props = {
  runTurn: (text: string, onChunk?: (delta: string) => void) => Promise<string>;
  statusFilePath: string;
};

function makeId(): string {
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
}

function greetingSalutation(date: Date): string {
  const h = date.getHours();
  if (h < 5) return 'boa madrugada';
  if (h < 12) return 'bom dia';
  if (h < 18) return 'boa tarde';
  return 'boa noite';
}

const PT_WEEKDAY = ['dom', 'seg', 'ter', 'qua', 'qui', 'sex', 'sáb'];

function greetingDateLine(date: Date): string {
  const wd = PT_WEEKDAY[date.getDay()];
  const dd = date.getDate().toString().padStart(2, '0');
  const mm = (date.getMonth() + 1).toString().padStart(2, '0');
  return `${wd} ${dd}/${mm}`;
}

function makeGreeting(now: Date): Message {
  const body = [
    `${greetingSalutation(now)}, daddy.`,
    greetingDateLine(now) + '.',
    '',
    'try',
    '  como tá o meu dia?',
    '  log: <pensamento>',
    '  o que escrevi sobre X?',
  ].join('\n');
  return { id: 'greeting', role: 'geo', text: body, timestamp: now, dim: true };
}

function StreamingLine({ text }: { text: string }): React.ReactElement {
  return (
    <Box flexDirection="row" paddingX={2} marginBottom={1}>
      <Text color={COLORS.geo} bold>
        {GLYPHS.geo}{' '}
      </Text>
      <Box flexDirection="column" flexGrow={1}>
        <Text>{text}</Text>
      </Box>
    </Box>
  );
}

export function App({ runTurn, statusFilePath }: Props): React.ReactElement {
  const { exit } = useApp();
  const status = useStatusFile(statusFilePath);
  const [messages, setMessages] = useState<Message[]>(() => [makeGreeting(new Date())]);
  const [inflight, setInflight] = useState(false);
  const [streamingText, setStreamingText] = useState<string | null>(null);
  const turnIdRef = useRef(0);
  const userHistoryRef = useRef<string[]>([]);

  const inflightRef = useRef(false);
  useEffect(() => { inflightRef.current = inflight; }, [inflight]);

  const append = useCallback((msg: Message): void => {
    setMessages((prev) => [...prev, msg]);
  }, []);

  const submit = useCallback(
    (text: string): void => {
      if (inflightRef.current) return;
      userHistoryRef.current.push(text);

      append({ id: makeId(), role: 'you', text, timestamp: new Date() });
      setInflight(true);
      setStreamingText('');
      const turnId = ++turnIdRef.current;
      runTurn(text, (delta: string) => {
        if (turnIdRef.current !== turnId) return;
        setStreamingText((prev) => (prev ?? '') + delta);
      })
        .then((reply) => {
          if (turnIdRef.current !== turnId) return;
          append({ id: makeId(), role: 'geo', text: reply || '(no reply)', timestamp: new Date() });
          setStreamingText(null);
          setInflight(false);
        })
        .catch((err: unknown) => {
          if (turnIdRef.current !== turnId) return;
          const msg = err instanceof Error ? err.message : String(err);
          append({
            id: makeId(),
            role: 'geo',
            text: `something went wrong: ${msg}`,
            timestamp: new Date(),
            error: true,
          });
          setStreamingText(null);
          setInflight(false);
        });
    },
    [append, runTurn],
  );

  const handleInput = useCallback(
    (input: string, key: { ctrl?: boolean; escape?: boolean }): void => {
      if (key.ctrl && input === 'c') {
        exit();
        return;
      }
      if (key.escape && inflightRef.current) {
        turnIdRef.current += 1;
        setInflight(false);
        setStreamingText(null);
        append({ id: makeId(), role: 'geo', text: '(canceled)', timestamp: new Date(), dim: true });
      }
    },
    [exit, append],
  );

  useInput(handleInput, { isActive: process.stdin.isTTY === true });

  const showStream = streamingText !== null && streamingText.length > 0;
  const showSpinner = inflight && (streamingText === null || streamingText.length === 0);

  return (
    <>
      <Static items={messages}>
        {(m) => <MessageLine key={m.id} message={m} />}
      </Static>
      {showStream ? <StreamingLine text={streamingText ?? ''} /> : null}
      {showSpinner ? <GeoSpinner /> : null}
      <Header status={status} />
      <Input disabled={inflight} onSubmit={submit} history={userHistoryRef.current} />
    </>
  );
}
