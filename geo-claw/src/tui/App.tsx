import React, { useCallback, useRef, useState } from 'react';
import { Box, Static, useApp, useInput } from 'ink';
import { Header } from './Header.js';
import { MessageLine, type Message } from './Conversation.js';
import { ThinkingDot } from './ThinkingDot.js';
import { Input } from './Input.js';
import { useStatusFile } from './useStatusFile.js';

type Props = {
  runTurn: (text: string) => Promise<string>;
  statusFilePath: string;
};

function makeId(): string {
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
}

export function App({ runTurn, statusFilePath }: Props): React.ReactElement {
  const { exit } = useApp();
  const status = useStatusFile(statusFilePath);
  const [messages, setMessages] = useState<Message[]>([]);
  const [inflight, setInflight] = useState(false);
  const turnIdRef = useRef(0);

  const append = useCallback((msg: Message): void => {
    setMessages((prev) => [...prev, msg]);
  }, []);

  const submit = useCallback(
    (text: string): void => {
      if (inflight) return;
      append({ id: makeId(), role: 'you', text });
      setInflight(true);
      const turnId = ++turnIdRef.current;
      runTurn(text)
        .then((reply) => {
          if (turnIdRef.current !== turnId) return;
          append({ id: makeId(), role: 'geo', text: reply || '(no reply)' });
          setInflight(false);
        })
        .catch((err: unknown) => {
          if (turnIdRef.current !== turnId) return;
          const msg = err instanceof Error ? err.message : String(err);
          append({ id: makeId(), role: 'geo', text: `something went wrong: ${msg}`, error: true });
          setInflight(false);
        });
    },
    [append, inflight, runTurn],
  );

  useInput(
    (_input, key) => {
      if (key.ctrl && _input === 'c') {
        exit();
        return;
      }
      if (key.ctrl && _input === 'l') {
        setMessages([]);
        return;
      }
      if (key.escape) {
        if (inflight) {
          turnIdRef.current += 1;
          setInflight(false);
          append({ id: makeId(), role: 'geo', text: '(canceled)', dim: true });
        }
      }
    },
    { isActive: process.stdin.isTTY === true },
  );

  return (
    <>
      <Static items={messages}>
        {(m) => <MessageLine key={m.id} message={m} />}
      </Static>
      <Box flexDirection="column">
        {inflight ? <ThinkingDot /> : null}
        <Header status={status} />
        <Input disabled={inflight} onSubmit={submit} />
      </Box>
    </>
  );
}
