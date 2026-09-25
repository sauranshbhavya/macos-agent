/**
 * Every open V2 session in this process, by account and by device.
 *
 * One device holds one session: a new connection from the same device replaces the old one. The
 * registry is also how the rest of the gateway reaches sockets: sign-out and account closure close
 * the account's sessions at once, and a deploy drains them all. With one gateway process this map
 * is the whole truth; more than one process would add Postgres LISTEN/NOTIFY (plan section 5).
 */
import type { GoodbyeReason } from "./close.js";
import type { Manifest, ServerTaskMessage } from "../protocol.js";

export interface SessionPeer {
  readonly accountId: string;
  readonly deviceId: string | undefined;
  /** What the device declared in its hello. */
  readonly manifest: Manifest | undefined;
  readonly providerSessionId: string | undefined;
  sendTask(messages: readonly ServerTaskMessage[]): void;
  goodbye(reason: GoodbyeReason): void;
}

export interface MessageRate {
  /** How many messages an account may send in a burst. */
  readonly burst: number;
  /** How many messages per second refill the burst. */
  readonly perSecond: number;
}

export const DEFAULT_MESSAGE_RATE: MessageRate = { burst: 120, perSecond: 20 };

interface Bucket {
  tokens: number;
  updatedAt: number;
}

export class SessionRegistry {
  private readonly byAccount = new Map<string, Set<SessionPeer>>();
  private readonly byDevice = new Map<string, SessionPeer>();
  private readonly buckets = new Map<string, Bucket>();
  private closing = false;

  constructor(private readonly rate: MessageRate = DEFAULT_MESSAGE_RATE) {}

  get draining(): boolean {
    return this.closing;
  }

  add(peer: SessionPeer): void {
    const peers = this.byAccount.get(peer.accountId) ?? new Set<SessionPeer>();
    peers.add(peer);
    this.byAccount.set(peer.accountId, peers);
  }

  /** Records which device a peer speaks for, and retires any older session from that device. */
  bindDevice(peer: SessionPeer, deviceId: string): void {
    const key = deviceKey(peer.accountId, deviceId);
    const previous = this.byDevice.get(key);
    this.byDevice.set(key, peer);
    if (previous !== undefined && previous !== peer) previous.goodbye("replaced");
  }

  remove(peer: SessionPeer): void {
    const peers = this.byAccount.get(peer.accountId);
    peers?.delete(peer);
    if (peers?.size === 0) {
      this.byAccount.delete(peer.accountId);
      this.buckets.delete(peer.accountId);
    }
    if (peer.deviceId !== undefined) {
      const key = deviceKey(peer.accountId, peer.deviceId);
      if (this.byDevice.get(key) === peer) this.byDevice.delete(key);
    }
  }

  peerFor(accountId: string, deviceId: string): SessionPeer | undefined {
    return this.byDevice.get(deviceKey(accountId, deviceId));
  }

  /** Closes every session opened under a provider session that has just been signed out. */
  signedOut(providerSessionId: string): void {
    for (const peers of this.byAccount.values()) {
      for (const peer of [...peers]) {
        if (peer.providerSessionId === providerSessionId) peer.goodbye("signed_out");
      }
    }
  }

  /** Closes every session of an account that has just been closed. */
  accountClosed(accountId: string): void {
    for (const peer of [...(this.byAccount.get(accountId) ?? [])]) peer.goodbye("signed_out");
  }

  /** Says goodbye to every session, for a deploy. New sessions are refused from here on. */
  drain(): void {
    this.closing = true;
    for (const peers of this.byAccount.values()) {
      for (const peer of [...peers]) peer.goodbye("draining");
    }
  }

  /** Spends one message from the account's token bucket. False means the account is over its rate. */
  allow(accountId: string, nowMs: number): boolean {
    const bucket = this.buckets.get(accountId) ?? { tokens: this.rate.burst, updatedAt: nowMs };
    const refilled = Math.min(
      this.rate.burst,
      bucket.tokens + ((nowMs - bucket.updatedAt) / 1000) * this.rate.perSecond,
    );
    const allowed = refilled >= 1;
    this.buckets.set(accountId, { tokens: allowed ? refilled - 1 : refilled, updatedAt: nowMs });
    return allowed;
  }

  get size(): number {
    let count = 0;
    for (const peers of this.byAccount.values()) count += peers.size;
    return count;
  }
}

function deviceKey(accountId: string, deviceId: string): string {
  return `${accountId}:${deviceId}`;
}
