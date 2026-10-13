import type MessageBusService from "discourse/services/message-bus";

// Core's MessageBusService declaration doesn't describe the client API it
// passes through (subscribe and unsubscribe); this adds it. Type-only.
export type MessageBus = MessageBusService & {
  // lastId: deliver messages after this one (default: only new ones)
  subscribe<T = unknown>(
    channel: string,
    callback: (data: T) => void,
    lastId?: number
  ): void;
  unsubscribe<T = unknown>(channel: string, callback?: (data: T) => void): void;
};
