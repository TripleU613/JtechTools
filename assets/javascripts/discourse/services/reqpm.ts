import { tracked } from "@glimmer/tracking";
import type Owner from "@ember/owner";
import Service, { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import type User from "discourse/models/user";
import type ModalService from "discourse/services/modal";
import type SiteSettingsService from "discourse/services/site-settings";
import ReqpmSetupModal from "../components/reqpm-setup-modal.gts";
import ReqpmUserModal from "../components/reqpm-user-modal.gts";
import type { MessageBus } from "../lib/message-bus.ts";
import type { ReqpmKindId } from "../lib/reqpm-kinds.ts";

const BASE = "/jtech-reqpm";

// ── Payloads (lib/discourse_reqpm/presenter.rb) ─────────────────────────

export type ReqpmSetupMode = "gentle" | "required";

// current_user.reqpm
export interface ReqpmUserSummary {
  available: boolean;
  setup_prompt?: ReqpmSetupMode | null;
  incoming_count?: number;
}

// BasicUserSerializer
export interface ReqpmBasicUser {
  id: number;
  username: string;
  name?: string | null;
  avatar_template: string;
}

// Who a REQ-PM window is about: a BasicUser from a payload, or the fields
// copied off a user card / profile model.
export interface ReqpmUserRef {
  id?: number;
  username: string;
  name?: string | null;
  avatar_template?: string;
}

// A method someone shared with you.
export interface ReqpmSharedMethod {
  id: number;
  kind: ReqpmKindId;
  label: string | null;
  emoji: string | null;
  value: string;
  note: string | null;
}

// One of your own methods.
export interface ReqpmOwnMethod extends ReqpmSharedMethod {
  share_by_default: boolean;
  position: number;
  unreadable: boolean;
}

export interface ReqpmCard {
  methods: ReqpmOwnMethod[];
  allow_requests: boolean;
  max_methods: number;
}

export interface ReqpmMethodAttrs {
  kind: ReqpmKindId;
  value: string;
  note: string;
  share_by_default: boolean;
  label?: string;
  emoji?: string;
}

export interface ReqpmMethodResponse {
  method: ReqpmOwnMethod;
}

export interface ReqpmSuccessResponse {
  success: string;
}

export type ReqpmOutgoingState = "answered" | "waiting" | "expired";

export interface ReqpmReceivedRow {
  user: ReqpmBasicUser;
  methods: ReqpmSharedMethod[];
  shared_at: string;
}

export interface ReqpmSentRow {
  user: ReqpmBasicUser;
  method_ids: number[];
  shared_at: string;
}

export interface ReqpmIncomingRequest {
  id: number;
  user: ReqpmBasicUser;
  wanted_kinds: ReqpmKindId[];
  created_at: string;
}

export interface ReqpmOutgoingRequest {
  id: number;
  user: ReqpmBasicUser;
  wanted_kinds: ReqpmKindId[];
  state: ReqpmOutgoingState;
  created_at: string;
  can_cancel: boolean;
}

export interface ReqpmInbox {
  received: ReqpmReceivedRow[];
  sent: ReqpmSentRow[];
  incoming: ReqpmIncomingRequest[];
  outgoing: ReqpmOutgoingRequest[];
}

export type ReqpmBlockedReason =
  | "self"
  | "unavailable"
  | "pending"
  | "cooldown";

export interface ReqpmRelationship {
  user: ReqpmBasicUser;
  their_methods: ReqpmSharedMethod[];
  my_methods: ReqpmOwnMethod[];
  my_shared_method_ids: number[];
  incoming_request: Omit<ReqpmIncomingRequest, "user"> | null;
  outgoing_request: Omit<ReqpmOutgoingRequest, "user"> | null;
  can_request: boolean;
  request_blocked: ReqpmBlockedReason | null;
  retry_at: string | null;
  can_share: boolean;
  share_blocked: ReqpmBlockedReason | null;
}

// ── Services ────────────────────────────────────────────────────────────

export type ReqpmCurrentUser = User & {
  id: number;
  username: string;
  reqpm?: ReqpmUserSummary;
};

export type ReqpmSiteSettings = SiteSettingsService & {
  reqpm_enabled: boolean;
  reqpm_default_country_code: string;
};

interface ReqpmStateMessage {
  incoming_count?: unknown;
}

// Client side of REQ-PM: the endpoints, the unanswered-requests badge, and
// opening the per-user window and the setup prompt. Contact values only ever
// pass through here on their way to the component showing them; nothing is
// cached or stored in the browser.
export default class ReqpmService extends Service {
  @service declare currentUser: ReqpmCurrentUser | null;
  @service declare siteSettings: ReqpmSiteSettings;
  @service declare messageBus: MessageBus;
  @service declare modal: ModalService;

  @tracked incomingCount = 0;
  // Bumped whenever the server says something changed for this user; open
  // REQ-PM views watch it and reload.
  @tracked refreshToken = 0;

  subscribed = false;

  onState = (data: unknown): void => {
    const state = data as ReqpmStateMessage | null | undefined;
    if (typeof state?.incoming_count === "number") {
      this.incomingCount = state.incoming_count;
    }
    this.refreshToken++;
  };

  onRefresh = (): void => {
    this.refreshToken++;
  };

  constructor(owner?: Owner) {
    super(owner);
    this.incomingCount = this.currentUser?.reqpm?.incoming_count || 0;
    if (this.available) {
      this.messageBus.subscribe("/reqpm/state", this.onState);
      this.messageBus.subscribe("/reqpm/refresh", this.onRefresh);
      this.subscribed = true;
    }
  }

  willDestroy() {
    super.willDestroy();
    if (this.subscribed) {
      this.messageBus.unsubscribe("/reqpm/state", this.onState);
      this.messageBus.unsubscribe("/reqpm/refresh", this.onRefresh);
    }
  }

  get available(): boolean {
    return !!(
      this.siteSettings.reqpm_enabled && this.currentUser?.reqpm?.available
    );
  }

  get setupPrompt(): ReqpmSetupMode | null {
    return this.currentUser?.reqpm?.setup_prompt || null;
  }

  // Called after the user adds their first method, snoozes or declines, so
  // the prompt does not come back before the next page load recomputes it.
  clearSetupPrompt(): void {
    if (this.currentUser?.reqpm) {
      this.currentUser.set("reqpm", {
        ...this.currentUser.reqpm,
        setup_prompt: null,
      });
    }
  }

  // ── Own card ──────────────────────────────────────────────────────────

  card(): Promise<ReqpmCard> {
    return ajax(`${BASE}/card.json`);
  }

  addMethod(attrs: ReqpmMethodAttrs): Promise<ReqpmMethodResponse> {
    return ajax(`${BASE}/card/methods.json`, {
      type: "POST",
      data: { reqpm_contact: attrs },
    });
  }

  updateMethod(
    id: number,
    attrs: ReqpmMethodAttrs
  ): Promise<ReqpmMethodResponse> {
    return ajax(`${BASE}/card/methods/${id}.json`, {
      type: "PUT",
      data: { reqpm_contact: attrs },
    });
  }

  deleteMethod(id: number): Promise<ReqpmSuccessResponse> {
    return ajax(`${BASE}/card/methods/${id}.json`, { type: "DELETE" });
  }

  reorder(ids: number[]): Promise<ReqpmCard> {
    return ajax(`${BASE}/card/methods/order.json`, {
      type: "PUT",
      data: { ids },
    });
  }

  setAllowRequests(allow: boolean): Promise<ReqpmCard> {
    return ajax(`${BASE}/card/preferences.json`, {
      type: "PUT",
      data: { allow_requests: allow },
    });
  }

  snoozeSetup(): Promise<ReqpmSuccessResponse> {
    return ajax(`${BASE}/card/setup/snooze.json`, { type: "POST" });
  }

  declineSetup(): Promise<ReqpmSuccessResponse> {
    return ajax(`${BASE}/card/setup/decline.json`, { type: "POST" });
  }

  // ── Between users ─────────────────────────────────────────────────────

  inbox(): Promise<ReqpmInbox> {
    return ajax(`${BASE}/inbox.json`);
  }

  relationship(username: string): Promise<ReqpmRelationship> {
    return ajax(`${BASE}/users/${encodeURIComponent(username)}.json`);
  }

  request(
    username: string,
    wantedKinds: ReqpmKindId[] = []
  ): Promise<ReqpmRelationship> {
    return ajax(`${BASE}/requests.json`, {
      type: "POST",
      data: { username, wanted_kinds: wantedKinds },
    });
  }

  declineRequest(id: number): Promise<ReqpmSuccessResponse> {
    return ajax(`${BASE}/requests/${id}/decline.json`, { type: "POST" });
  }

  cancelRequest(id: number): Promise<ReqpmSuccessResponse> {
    return ajax(`${BASE}/requests/${id}.json`, { type: "DELETE" });
  }

  share(username: string, methodIds: number[]): Promise<ReqpmRelationship> {
    return ajax(`${BASE}/shares.json`, {
      type: "POST",
      data: { username, method_ids: methodIds },
    });
  }

  revoke(username: string): Promise<ReqpmRelationship> {
    return ajax(`${BASE}/shares/${encodeURIComponent(username)}.json`, {
      type: "DELETE",
    });
  }

  forget(username: string): Promise<ReqpmSuccessResponse> {
    return ajax(`${BASE}/received/${encodeURIComponent(username)}.json`, {
      type: "DELETE",
    });
  }

  // ── Windows ───────────────────────────────────────────────────────────

  openUser(user: ReqpmUserRef): Promise<unknown> {
    return this.modal.show(ReqpmUserModal, { model: { user } });
  }

  openSetup(mode: ReqpmSetupMode): Promise<unknown> {
    return this.modal.show(ReqpmSetupModal, { model: { mode } });
  }
}

declare module "@ember/service" {
  interface Registry {
    reqpm: ReqpmService;
  }
}

export interface ReqpmErrorInfo {
  message: string | null;
  reason: string | null;
  field: string | null;
}

interface ReqpmErrorJson {
  errors?: string[];
  extras?: { reason?: string; field?: string; retry_at?: string };
}

// Server errors with a known reason (e.g. "cooldown") come back as
// { errors: [message], extras: { reason, field, retry_at } }.
export function reqpmError(error: unknown): ReqpmErrorInfo {
  const json = (
    error as { jqXHR?: { responseJSON?: ReqpmErrorJson } } | null | undefined
  )?.jqXHR?.responseJSON;
  return {
    message: json?.errors?.[0] || null,
    reason: json?.extras?.reason || null,
    field: json?.extras?.field || null,
  };
}
