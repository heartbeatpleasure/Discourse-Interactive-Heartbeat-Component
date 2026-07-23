import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import { ajax } from "discourse/lib/ajax";
import { i18n } from "discourse-i18n";
import { themePrefix } from "virtual:theme";

function t(key, options) {
  return i18n(themePrefix(key), options);
}

function avatarUrl(user, size = 64) {
  return String(user?.avatar_template || "").replace("{size}", String(size));
}

function errorMessage(error, fallback) {
  return (
    error?.jqXHR?.responseJSON?.message ||
    error?.responseJSON?.message ||
    error?.message ||
    fallback
  );
}

export default class InteractiveHeartbeatPage extends Component {
  @service router;

  @tracked loading = true;
  @tracked config = null;
  @tracked sessions = [];
  @tracked query = "";
  @tracked suggestions = [];
  @tracked selectedUser = null;
  @tracked searching = false;
  @tracked creating = false;
  @tracked outbound = true;
  @tracked inbound = true;
  @tracked error = null;
  @tracked notice = null;
  @tracked history = {
    total: 0,
    shown: 0,
    expanded: false,
    has_more: false,
    default_limit: 5,
  };
  @tracked clearingCompleted = false;
  @tracked confirmingClearCompleted = false;
  @tracked invitationPreferences = null;
  @tracked invitationPreferencesLoading = true;
  @tracked invitationPreferencesError = null;
  @tracked savingInvitationMode = false;
  @tracked approvedQuery = "";
  @tracked approvedSuggestions = [];
  @tracked approvedSelectedUser = null;
  @tracked approvedSearching = false;
  @tracked approvedSaving = false;
  @tracked blockedQuery = "";
  @tracked blockedSuggestions = [];
  @tracked blockedSelectedUser = null;
  @tracked blockedSearching = false;
  @tracked blockedSaving = false;

  searchTimer = null;
  searchSequence = 0;
  approvedSearchTimer = null;
  approvedSearchSequence = 0;
  blockedSearchTimer = null;
  blockedSearchSequence = 0;

  willDestroy() {
    if (super.willDestroy) {
      super.willDestroy(...arguments);
    }
    window.clearTimeout(this.searchTimer);
    window.clearTimeout(this.approvedSearchTimer);
    window.clearTimeout(this.blockedSearchTimer);
  }

  get title() {
    return t("interactive_heartbeat.title");
  }

  get subtitle() {
    return t("interactive_heartbeat.subtitle");
  }

  get canCreate() {
    return Boolean(
      this.selectedUser && (this.outbound || this.inbound) && !this.creating,
    );
  }

  get createButtonDisabled() {
    return !this.canCreate;
  }

  get invitationModeOptions() {
    const modes = this.invitationPreferences?.available_modes || [];
    return modes.map((mode) => ({
      value: mode,
      selected: this.invitationPreferences?.mode === mode,
      label: t(`interactive_heartbeat.invitation_preferences.modes.${mode}.label`),
      description: t(
        `interactive_heartbeat.invitation_preferences.modes.${mode}.description`,
      ),
    }));
  }

  get approvedMembers() {
    return this.invitationPreferences?.approved_members || [];
  }

  get blockedMembers() {
    return this.invitationPreferences?.blocked_members || [];
  }

  get approvedOnlyMode() {
    return this.invitationPreferences?.mode === "approved_members";
  }

  get allMembersMode() {
    return this.invitationPreferences?.mode === "all_members";
  }

  get canAddApprovedMember() {
    return Boolean(this.approvedSelectedUser) && !this.approvedSaving;
  }

  get canAddBlockedMember() {
    return Boolean(this.blockedSelectedUser) && !this.blockedSaving;
  }

  get approvedAddDisabled() {
    return !this.canAddApprovedMember;
  }

  get blockedAddDisabled() {
    return !this.canAddBlockedMember;
  }

  get currentSessions() {
    return this.sessions.filter((session) => !session.terminal);
  }

  get completedSessions() {
    return this.sessions.filter((session) => session.terminal);
  }

  get hasAnySessions() {
    return this.currentSessions.length > 0 || this.completedSessions.length > 0;
  }

  get hasCompletedHistory() {
    return Number(this.history?.total || 0) > 0;
  }

  get canShowMoreCompleted() {
    return this.history?.has_more === true && this.history?.expanded !== true;
  }

  get completedHistoryTruncated() {
    return this.history?.truncated === true;
  }

  formatSessionDate(value) {
    if (!value) {
      return "";
    }

    const date = new Date(value);
    if (Number.isNaN(date.getTime())) {
      return "";
    }

    try {
      return new Intl.DateTimeFormat(undefined, {
        dateStyle: "medium",
        timeStyle: "short",
      }).format(date);
    } catch {
      return date.toLocaleString();
    }
  }

  decorateSession(session) {
    const other = session?.other_user?.user;
    const terminal = session?.terminal === true;
    const activityDate = this.formatSessionDate(session.activity_at);
    const activityKey = terminal
      ? "completed_on"
      : session.status === "invited"
        ? "invited_on"
        : "updated_on";
    return {
      ...session,
      terminal,
      other_user: session.other_user
        ? {
            ...session.other_user,
            user: {
              ...other,
              avatar_url: avatarUrl(other),
            },
          }
        : null,
      status_label: t(`interactive_heartbeat.status.${session.status}`),
      activity_label: activityDate
        ? t(`interactive_heartbeat.overview.${activityKey}`, {
            date: activityDate,
          })
        : "",
      href: terminal ? null : `/interactive-heartbeat/sessions/${session.token}`,
    };
  }

  @action
  async setup() {
    await this.load();
  }

  async load({ historyAll = this.history?.expanded === true } = {}) {
    this.loading = true;
    this.error = null;

    try {
      this.config = await ajax("/interactive-heartbeat/api/config");
    } catch (error) {
      this.config = null;
      this.sessions = [];
      this.error = errorMessage(
        error,
        t("interactive_heartbeat.errors.config_load_failed"),
      );
      this.loading = false;
      return;
    }

    await this.loadInvitationPreferences();

    try {
      const sessions = await ajax("/interactive-heartbeat/api/sessions", {
        data: { history_all: historyAll },
      });
      this.sessions = (sessions?.sessions || []).map((session) =>
        this.decorateSession(session),
      );
      this.history = sessions?.history || this.history;
      this.confirmingClearCompleted = false;
    } catch (error) {
      this.sessions = [];
      this.error = errorMessage(
        error,
        t("interactive_heartbeat.errors.sessions_load_failed"),
      );
    } finally {
      this.loading = false;
    }
  }

  decoratePreferenceResponse(response) {
    const decorate = (users) =>
      (users || []).map((user) => ({
        ...user,
        avatar_url: avatarUrl(user, 48),
      }));

    return {
      ...response,
      approved_members: decorate(response?.approved_members),
      blocked_members: decorate(response?.blocked_members),
    };
  }

  async loadInvitationPreferences() {
    this.invitationPreferencesLoading = true;
    this.invitationPreferencesError = null;
    try {
      const response = await ajax(
        "/interactive-heartbeat/api/invitation-preferences",
      );
      this.invitationPreferences = this.decoratePreferenceResponse(response);
    } catch (error) {
      this.invitationPreferences = null;
      this.invitationPreferencesError = errorMessage(
        error,
        t("interactive_heartbeat.errors.invitation_preferences_load_failed"),
      );
    } finally {
      this.invitationPreferencesLoading = false;
    }
  }

  @action
  async updateInvitationMode(mode) {
    if (this.savingInvitationMode || this.invitationPreferences?.mode === mode) {
      return;
    }

    this.savingInvitationMode = true;
    this.invitationPreferencesError = null;
    try {
      const response = await ajax(
        "/interactive-heartbeat/api/invitation-preferences",
        { type: "PUT", data: { mode } },
      );
      this.invitationPreferences = this.decoratePreferenceResponse(response);
      this.notice = t("interactive_heartbeat.invitation_preferences.saved");
      await this.load({ historyAll: this.history?.expanded === true });
    } catch (error) {
      this.invitationPreferencesError = errorMessage(
        error,
        t("interactive_heartbeat.errors.invitation_preferences_save_failed"),
      );
    } finally {
      this.savingInvitationMode = false;
    }
  }

  @action
  updateInvitationSearch(kind, event) {
    const value = event.target.value;
    const approved = kind === "approved";
    if (approved) {
      this.approvedQuery = value;
      this.approvedSelectedUser = null;
      window.clearTimeout(this.approvedSearchTimer);
    } else {
      this.blockedQuery = value;
      this.blockedSelectedUser = null;
      window.clearTimeout(this.blockedSearchTimer);
    }

    const query = value.trim();
    if (query.length < 2) {
      if (approved) {
        this.approvedSuggestions = [];
        this.approvedSearching = false;
      } else {
        this.blockedSuggestions = [];
        this.blockedSearching = false;
      }
      return;
    }

    const sequence = approved
      ? ++this.approvedSearchSequence
      : ++this.blockedSearchSequence;
    if (approved) {
      this.approvedSearching = true;
    } else {
      this.blockedSearching = true;
    }

    const timer = window.setTimeout(async () => {
      try {
        const response = await ajax("/interactive-heartbeat/api/users", {
          data: { q: query, purpose: "invitation_preferences" },
        });
        const existingIds = new Set(
          (approved ? this.approvedMembers : this.blockedMembers).map(
            (user) => user.id,
          ),
        );
        const suggestions = (response?.users || [])
          .filter((user) => !existingIds.has(user.id))
          .map((user) => ({
            ...user,
            avatar_url: avatarUrl(user, 48),
          }));
        if (approved && sequence === this.approvedSearchSequence) {
          this.approvedSuggestions = suggestions;
        } else if (!approved && sequence === this.blockedSearchSequence) {
          this.blockedSuggestions = suggestions;
        }
      } catch (error) {
        this.invitationPreferencesError = errorMessage(
          error,
          t("interactive_heartbeat.errors.user_search_failed"),
        );
      } finally {
        if (approved && sequence === this.approvedSearchSequence) {
          this.approvedSearching = false;
        } else if (!approved && sequence === this.blockedSearchSequence) {
          this.blockedSearching = false;
        }
      }
    }, 250);

    if (approved) {
      this.approvedSearchTimer = timer;
    } else {
      this.blockedSearchTimer = timer;
    }
  }

  @action
  selectInvitationUser(kind, user) {
    if (kind === "approved") {
      this.approvedSelectedUser = user;
      this.approvedQuery = user.username;
      this.approvedSuggestions = [];
    } else {
      this.blockedSelectedUser = user;
      this.blockedQuery = user.username;
      this.blockedSuggestions = [];
    }
  }

  @action
  async addInvitationMember(kind) {
    const approved = kind === "approved";
    const user = approved ? this.approvedSelectedUser : this.blockedSelectedUser;
    if (!user || (approved ? this.approvedSaving : this.blockedSaving)) {
      return;
    }

    if (approved) {
      this.approvedSaving = true;
    } else {
      this.blockedSaving = true;
    }
    this.invitationPreferencesError = null;
    try {
      const response = await ajax(
        "/interactive-heartbeat/api/invitation-preferences/members",
        { type: "POST", data: { username: user.username, kind } },
      );
      this.invitationPreferences = this.decoratePreferenceResponse(response);
      if (approved) {
        this.approvedQuery = "";
        this.approvedSelectedUser = null;
        this.approvedSuggestions = [];
      } else {
        this.blockedQuery = "";
        this.blockedSelectedUser = null;
        this.blockedSuggestions = [];
      }
      this.notice = t(
        approved
          ? "interactive_heartbeat.invitation_preferences.approved_added"
          : "interactive_heartbeat.invitation_preferences.blocked_added",
      );
      await this.load({ historyAll: this.history?.expanded === true });
    } catch (error) {
      this.invitationPreferencesError = errorMessage(
        error,
        t("interactive_heartbeat.errors.invitation_member_save_failed"),
      );
    } finally {
      if (approved) {
        this.approvedSaving = false;
      } else {
        this.blockedSaving = false;
      }
    }
  }

  @action
  async removeInvitationMember(kind, user) {
    this.invitationPreferencesError = null;
    try {
      const response = await ajax(
        `/interactive-heartbeat/api/invitation-preferences/members/${user.id}`,
        { type: "DELETE", data: { kind } },
      );
      this.invitationPreferences = this.decoratePreferenceResponse(response);
      this.notice = t("interactive_heartbeat.invitation_preferences.member_removed");
    } catch (error) {
      this.invitationPreferencesError = errorMessage(
        error,
        t("interactive_heartbeat.errors.invitation_member_remove_failed"),
      );
    }
  }

  @action
  updateQuery(event) {
    this.query = event.target.value;
    this.selectedUser = null;
    this.notice = null;
    window.clearTimeout(this.searchTimer);

    const query = this.query.trim();
    if (query.length < 2) {
      this.suggestions = [];
      this.searching = false;
      return;
    }

    const sequence = ++this.searchSequence;
    this.searching = true;
    this.searchTimer = window.setTimeout(async () => {
      try {
        const response = await ajax("/interactive-heartbeat/api/users", {
          data: { q: query },
        });
        if (sequence !== this.searchSequence) {
          return;
        }
        this.suggestions = (response?.users || []).map((user) => ({
          ...user,
          avatar_url: avatarUrl(user, 48),
        }));
      } catch (error) {
        if (sequence === this.searchSequence) {
          this.error = errorMessage(
            error,
            t("interactive_heartbeat.errors.user_search_failed"),
          );
        }
      } finally {
        if (sequence === this.searchSequence) {
          this.searching = false;
        }
      }
    }, 250);
  }

  @action
  selectUser(user) {
    this.selectedUser = user;
    this.query = user.username;
    this.suggestions = [];
  }

  @action
  updateOutbound(event) {
    this.outbound = event.target.checked;
  }

  @action
  updateInbound(event) {
    this.inbound = event.target.checked;
  }

  @action
  async createSession() {
    if (!this.canCreate) {
      return;
    }

    this.creating = true;
    this.error = null;
    const directions = [];
    if (this.outbound) {
      directions.push("initiator_to_invitee");
    }
    if (this.inbound) {
      directions.push("invitee_to_initiator");
    }

    try {
      const session = await ajax("/interactive-heartbeat/api/sessions", {
        type: "POST",
        data: {
          username: this.selectedUser.username,
          directions,
        },
      });
      this.router.transitionTo("interactive-heartbeat-session", session.token);
    } catch (error) {
      this.error = errorMessage(
        error,
        t("interactive_heartbeat.errors.create_failed"),
      );
    } finally {
      this.creating = false;
    }
  }

  @action
  async showAllCompleted() {
    await this.load({ historyAll: true });
  }

  @action
  async showRecentCompleted() {
    await this.load({ historyAll: false });
  }

  @action
  askClearCompleted() {
    this.confirmingClearCompleted = true;
  }

  @action
  cancelClearCompleted() {
    this.confirmingClearCompleted = false;
  }

  @action
  async clearCompleted() {
    if (this.clearingCompleted) {
      return;
    }

    this.clearingCompleted = true;
    this.error = null;
    try {
      const response = await ajax(
        "/interactive-heartbeat/api/sessions/completed",
        { type: "DELETE" },
      );
      this.notice = t("interactive_heartbeat.overview.completed_cleared", {
        count: Number(response?.cleared || 0),
      });
      this.history = {
        total: 0,
        shown: 0,
        expanded: false,
        has_more: false,
        default_limit: 5,
      };
      await this.load({ historyAll: false });
    } catch (error) {
      this.error = errorMessage(
        error,
        t("interactive_heartbeat.errors.clear_completed_failed"),
      );
    } finally {
      this.clearingCompleted = false;
      this.confirmingClearCompleted = false;
    }
  }

  @action
  async copyInvite(session) {
    try {
      await navigator.clipboard.writeText(session.invite_url);
      this.notice = t("interactive_heartbeat.overview.copied");
    } catch {
      this.notice = session.invite_url;
    }
  }

  <template>
    <div class="interactive-heartbeat" {{didInsert this.setup}}>
      <section class="interactive-heartbeat__hero">
        <div>
          <h1>{{this.title}}</h1>
          <p>{{this.subtitle}}</p>
        </div>
      </section>

      {{#if this.error}}
        <div
          class="interactive-heartbeat__alert interactive-heartbeat__alert--error"
          role="alert"
        >
          {{this.error}}
        </div>
      {{/if}}

      {{#if this.notice}}
        <div
          class="interactive-heartbeat__alert interactive-heartbeat__alert--success"
          role="status"
        >
          {{this.notice}}
        </div>
      {{/if}}

      {{#if this.loading}}
        <div class="interactive-heartbeat__card">
          <p>{{t "interactive_heartbeat.loading"}}</p>
        </div>
      {{else}}
        {{#if this.config}}
          {{#unless this.config.heartrate_runtime_ready}}
            <div
              class="interactive-heartbeat__alert interactive-heartbeat__alert--warning"
            >
              Interactive Heartbeat requires the Heartrate plugin's asynchronous
              current readings to be enabled.
            </div>
          {{/unless}}

          {{#unless this.config.lovense_configured}}
            <div
              class="interactive-heartbeat__alert interactive-heartbeat__alert--warning"
            >
              {{t "interactive_heartbeat.lovense.not_configured"}}
            </div>
          {{/unless}}
        {{/if}}

        <section class="interactive-heartbeat__card">
          <div class="interactive-heartbeat__card-header">
            <div>
              <h2>{{t "interactive_heartbeat.overview.new_session"}}</h2>
              <p>{{t "interactive_heartbeat.overview.new_session_help"}}</p>
            </div>
          </div>

          <label class="interactive-heartbeat__field">
            <span>{{t "interactive_heartbeat.overview.member"}}</span>
            <input
              type="text"
              value={{this.query}}
              placeholder={{t
                "interactive_heartbeat.overview.member_placeholder"
              }}
              autocomplete="off"
              {{on "input" this.updateQuery}}
            />
          </label>

          {{#if this.searching}}
            <p class="interactive-heartbeat__muted">Searching…</p>
          {{/if}}

          {{#if this.suggestions.length}}
            <div class="interactive-heartbeat__suggestions" role="listbox">
              {{#each this.suggestions as |user|}}
                <button
                  type="button"
                  class="interactive-heartbeat__suggestion"
                  {{on "click" (fn this.selectUser user)}}
                >
                  <img src={{user.avatar_url}} alt="" />
                  <span>
                    <strong>{{user.username}}</strong>
                    {{#if user.name}}<small>{{user.name}}</small>{{/if}}
                  </span>
                </button>
              {{/each}}
            </div>
          {{/if}}

          <fieldset class="interactive-heartbeat__fieldset">
            <legend>{{t
                "interactive_heartbeat.overview.direction_title"
              }}</legend>
            <label>
              <input
                type="checkbox"
                checked={{this.outbound}}
                {{on "change" this.updateOutbound}}
              />
              <span>{{t "interactive_heartbeat.overview.outbound"}}</span>
            </label>
            <label>
              <input
                type="checkbox"
                checked={{this.inbound}}
                {{on "change" this.updateInbound}}
              />
              <span>{{t "interactive_heartbeat.overview.inbound"}}</span>
            </label>
          </fieldset>

          <button
            type="button"
            class="btn btn-primary"
            disabled={{this.createButtonDisabled}}
            {{on "click" this.createSession}}
          >
            {{#if this.creating}}
              {{t "interactive_heartbeat.overview.creating"}}
            {{else}}
              {{t "interactive_heartbeat.overview.create_and_allow"}}
            {{/if}}
          </button>
        </section>

        <section class="interactive-heartbeat__card interactive-heartbeat__invitation-preferences">
          <div class="interactive-heartbeat__card-header">
            <div>
              <h2>{{t "interactive_heartbeat.invitation_preferences.title"}}</h2>
              <p>{{t "interactive_heartbeat.invitation_preferences.help"}}</p>
            </div>
          </div>

          {{#if this.invitationPreferencesError}}
            <div class="interactive-heartbeat__alert interactive-heartbeat__alert--error" role="alert">
              {{this.invitationPreferencesError}}
            </div>
          {{/if}}

          {{#if this.invitationPreferencesLoading}}
            <p>{{t "interactive_heartbeat.loading"}}</p>
          {{else if this.invitationPreferences}}
            <fieldset class="interactive-heartbeat__choice-fieldset" disabled={{this.savingInvitationMode}}>
              <legend>{{t "interactive_heartbeat.invitation_preferences.who_can_invite"}}</legend>
              <div class="interactive-heartbeat__choice-grid interactive-heartbeat__choice-grid--preference-modes" role="radiogroup">
                {{#each this.invitationModeOptions as |option|}}
                  <label class="interactive-heartbeat__choice">
                    <input
                      type="radio"
                      name="interactive-heartbeat-invitation-mode"
                      value={{option.value}}
                      checked={{option.selected}}
                      {{on "change" (fn this.updateInvitationMode option.value)}}
                    />
                    <span class="interactive-heartbeat__choice-content">
                      <strong>{{option.label}}</strong>
                      <small>{{option.description}}</small>
                    </span>
                  </label>
                {{/each}}
              </div>
            </fieldset>

            {{#if this.approvedOnlyMode}}
              <section class="interactive-heartbeat__preference-list-section">
                <div class="interactive-heartbeat__preference-list-header">
                  <div>
                    <h3>{{t "interactive_heartbeat.invitation_preferences.approved_title"}}</h3>
                    <p>{{t "interactive_heartbeat.invitation_preferences.approved_help"}}</p>
                  </div>
                </div>
                <div class="interactive-heartbeat__preference-search-row">
                  <label class="interactive-heartbeat__field">
                    <span>{{t "interactive_heartbeat.invitation_preferences.search_member"}}</span>
                    <input
                      type="text"
                      value={{this.approvedQuery}}
                      placeholder={{t "interactive_heartbeat.invitation_preferences.search_placeholder"}}
                      autocomplete="off"
                      {{on "input" (fn this.updateInvitationSearch "approved")}}
                    />
                  </label>
                  <button
                    type="button"
                    class="btn btn-primary"
                    disabled={{this.approvedAddDisabled}}
                    {{on "click" (fn this.addInvitationMember "approved")}}
                  >
                    {{t "interactive_heartbeat.invitation_preferences.add"}}
                  </button>
                </div>
                {{#if this.approvedSearching}}
                  <p class="interactive-heartbeat__muted">{{t "interactive_heartbeat.invitation_preferences.searching"}}</p>
                {{/if}}
                {{#if this.approvedSuggestions.length}}
                  <div class="interactive-heartbeat__suggestions" role="listbox">
                    {{#each this.approvedSuggestions as |user|}}
                      <button type="button" class="interactive-heartbeat__suggestion" {{on "click" (fn this.selectInvitationUser "approved" user)}}>
                        <img src={{user.avatar_url}} alt="" />
                        <span><strong>{{user.username}}</strong>{{#if user.name}}<small>{{user.name}}</small>{{/if}}</span>
                      </button>
                    {{/each}}
                  </div>
                {{/if}}
                {{#if this.approvedMembers.length}}
                  <div class="interactive-heartbeat__preference-member-list">
                    {{#each this.approvedMembers as |user|}}
                      <article class="interactive-heartbeat__preference-member-row">
                        <div class="interactive-heartbeat__member">
                          <img src={{user.avatar_url}} alt="" />
                          <strong>{{user.username}}</strong>
                        </div>
                        <button type="button" class="btn" {{on "click" (fn this.removeInvitationMember "approved" user)}}>
                          {{t "interactive_heartbeat.invitation_preferences.remove"}}
                        </button>
                      </article>
                    {{/each}}
                  </div>
                {{else}}
                  <p class="interactive-heartbeat__muted">{{t "interactive_heartbeat.invitation_preferences.no_approved"}}</p>
                {{/if}}
                {{#if this.blockedMembers.length}}
                  <p class="interactive-heartbeat__muted interactive-heartbeat__preference-retained-note">
                    {{t "interactive_heartbeat.invitation_preferences.blocked_list_retained"}}
                  </p>
                {{/if}}
              </section>
            {{/if}}

            {{#if this.allMembersMode}}
            <section class="interactive-heartbeat__preference-list-section">
              <div class="interactive-heartbeat__preference-list-header">
                <div>
                  <h3>{{t "interactive_heartbeat.invitation_preferences.blocked_title"}}</h3>
                  <p>{{t "interactive_heartbeat.invitation_preferences.blocked_help"}}</p>
                </div>
              </div>
              <div class="interactive-heartbeat__preference-search-row">
                <label class="interactive-heartbeat__field">
                  <span>{{t "interactive_heartbeat.invitation_preferences.search_member"}}</span>
                  <input
                    type="text"
                    value={{this.blockedQuery}}
                    placeholder={{t "interactive_heartbeat.invitation_preferences.search_placeholder"}}
                    autocomplete="off"
                    {{on "input" (fn this.updateInvitationSearch "blocked")}}
                  />
                </label>
                <button
                  type="button"
                  class="btn btn-primary"
                  disabled={{this.blockedAddDisabled}}
                  {{on "click" (fn this.addInvitationMember "blocked")}}
                >
                  {{t "interactive_heartbeat.invitation_preferences.add"}}
                </button>
              </div>
              {{#if this.blockedSearching}}
                <p class="interactive-heartbeat__muted">{{t "interactive_heartbeat.invitation_preferences.searching"}}</p>
              {{/if}}
              {{#if this.blockedSuggestions.length}}
                <div class="interactive-heartbeat__suggestions" role="listbox">
                  {{#each this.blockedSuggestions as |user|}}
                    <button type="button" class="interactive-heartbeat__suggestion" {{on "click" (fn this.selectInvitationUser "blocked" user)}}>
                      <img src={{user.avatar_url}} alt="" />
                      <span><strong>{{user.username}}</strong>{{#if user.name}}<small>{{user.name}}</small>{{/if}}</span>
                    </button>
                  {{/each}}
                </div>
              {{/if}}
              {{#if this.blockedMembers.length}}
                <div class="interactive-heartbeat__preference-member-list">
                  {{#each this.blockedMembers as |user|}}
                    <article class="interactive-heartbeat__preference-member-row">
                      <div class="interactive-heartbeat__member">
                        <img src={{user.avatar_url}} alt="" />
                        <strong>{{user.username}}</strong>
                      </div>
                      <button type="button" class="btn" {{on "click" (fn this.removeInvitationMember "blocked" user)}}>
                        {{t "interactive_heartbeat.invitation_preferences.remove"}}
                      </button>
                    </article>
                  {{/each}}
                </div>
              {{else}}
                <p class="interactive-heartbeat__muted">{{t "interactive_heartbeat.invitation_preferences.no_blocked"}}</p>
              {{/if}}
            </section>
            {{/if}}
          {{/if}}
        </section>

        {{#if this.config.test_lab_enabled}}
          <section class="interactive-heartbeat__card interactive-heartbeat__test-lab-entry">
            <div class="interactive-heartbeat__card-header">
              <div>
                <span class="interactive-heartbeat__eyebrow">Admin only</span>
                <h2>{{t "interactive_heartbeat.test_lab.title"}}</h2>
                <p>{{t "interactive_heartbeat.test_lab.entry_help"}}</p>
              </div>
              <a class="btn btn-primary" href={{this.config.test_lab_url}}>
                {{t "interactive_heartbeat.test_lab.open"}}
              </a>
            </div>
          </section>
        {{/if}}

        <section class="interactive-heartbeat__card interactive-heartbeat__sessions-card">
          <div class="interactive-heartbeat__card-header">
            <div>
              <h2>{{t "interactive_heartbeat.overview.sessions"}}</h2>
              <p>{{t "interactive_heartbeat.overview.sessions_help"}}</p>
            </div>
          </div>

          {{#if this.currentSessions.length}}
            <section class="interactive-heartbeat__session-group">
              <h3>{{t "interactive_heartbeat.overview.current_sessions"}}</h3>
              <div class="interactive-heartbeat__session-list">
                {{#each this.currentSessions as |session|}}
                  <article class="interactive-heartbeat__session-row">
                    <div class="interactive-heartbeat__member">
                      <img src={{session.other_user.user.avatar_url}} alt="" />
                      <div>
                        <strong>{{session.other_user.user.username}}</strong>
                        <span>{{session.status_label}}</span>
                        {{#if session.activity_label}}
                          <small>{{session.activity_label}}</small>
                        {{/if}}
                      </div>
                    </div>
                    <div class="interactive-heartbeat__actions interactive-heartbeat__session-actions">
                      {{#if session.can_copy_invite}}
                        <button
                          type="button"
                          class="btn"
                          {{on "click" (fn this.copyInvite session)}}
                        >
                          {{t "interactive_heartbeat.overview.copy"}}
                        </button>
                      {{/if}}
                      {{#if session.can_open}}
                        <a class="btn btn-primary" href={{session.href}}>
                          {{t "interactive_heartbeat.overview.open"}}
                        </a>
                      {{/if}}
                    </div>
                  </article>
                {{/each}}
              </div>
            </section>
          {{/if}}

          {{#if this.hasCompletedHistory}}
            <section class="interactive-heartbeat__session-group interactive-heartbeat__session-group--completed">
              <div class="interactive-heartbeat__session-group-header">
                <div>
                  <h3>{{t "interactive_heartbeat.overview.completed_sessions"}}</h3>
                  <p>{{t "interactive_heartbeat.overview.completed_sessions_help"}}</p>
                </div>
                <div class="interactive-heartbeat__actions interactive-heartbeat__history-actions">
                  {{#if this.canShowMoreCompleted}}
                    <button type="button" class="btn" {{on "click" this.showAllCompleted}}>
                      {{t "interactive_heartbeat.overview.show_completed_history" count=this.history.total}}
                    </button>
                  {{else if this.history.expanded}}
                    <button type="button" class="btn" {{on "click" this.showRecentCompleted}}>
                      {{t "interactive_heartbeat.overview.show_recent_completed"}}
                    </button>
                  {{/if}}
                  <button type="button" class="btn btn-danger" {{on "click" this.askClearCompleted}}>
                    {{t "interactive_heartbeat.overview.clear_completed"}}
                  </button>
                </div>
              </div>

              {{#if this.confirmingClearCompleted}}
                <div class="interactive-heartbeat__clear-confirmation" role="alert">
                  <div>
                    <strong>{{t "interactive_heartbeat.overview.clear_completed_confirm_title"}}</strong>
                    <p>{{t "interactive_heartbeat.overview.clear_completed_confirm_help"}}</p>
                  </div>
                  <div class="interactive-heartbeat__actions">
                    <button type="button" class="btn" {{on "click" this.cancelClearCompleted}}>
                      {{t "interactive_heartbeat.overview.cancel"}}
                    </button>
                    <button
                      type="button"
                      class="btn btn-danger"
                      disabled={{this.clearingCompleted}}
                      {{on "click" this.clearCompleted}}
                    >
                      {{#if this.clearingCompleted}}
                        {{t "interactive_heartbeat.overview.clearing_completed"}}
                      {{else}}
                        {{t "interactive_heartbeat.overview.confirm_clear_completed"}}
                      {{/if}}
                    </button>
                  </div>
                </div>
              {{/if}}

              {{#if this.completedHistoryTruncated}}
                <p class="interactive-heartbeat__muted">
                  {{t
                    "interactive_heartbeat.overview.completed_history_truncated"
                    shown=this.history.shown
                    total=this.history.total
                  }}
                </p>
              {{/if}}

              <div class="interactive-heartbeat__session-list">
                {{#each this.completedSessions as |session|}}
                  <article class="interactive-heartbeat__session-row interactive-heartbeat__session-row--completed">
                    <div class="interactive-heartbeat__member">
                      <img src={{session.other_user.user.avatar_url}} alt="" />
                      <div>
                        <strong>{{session.other_user.user.username}}</strong>
                        <span>{{session.status_label}}</span>
                        {{#if session.activity_label}}
                          <small>{{session.activity_label}}</small>
                        {{/if}}
                      </div>
                    </div>
                  </article>
                {{/each}}
              </div>
            </section>
          {{/if}}

          {{#unless this.hasAnySessions}}
            <p class="interactive-heartbeat__muted">{{t
                "interactive_heartbeat.overview.no_sessions"
              }}</p>
          {{/unless}}
        </section>
      {{/if}}
    </div>
  </template>
}
