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

  searchTimer = null;
  searchSequence = 0;

  willDestroy() {
    if (super.willDestroy) {
      super.willDestroy(...arguments);
    }
    window.clearTimeout(this.searchTimer);
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

  decorateSession(session) {
    const other = session?.other_user?.user;
    return {
      ...session,
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
      href: `/interactive-heartbeat/sessions/${session.token}`,
    };
  }

  @action
  async setup() {
    await this.load();
  }

  async load() {
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

    try {
      const sessions = await ajax("/interactive-heartbeat/api/sessions");
      this.sessions = (sessions?.sessions || []).map((session) =>
        this.decorateSession(session),
      );
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
              <p>Both participants must explicitly accept the session and
                consent to each active direction.</p>
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
              {{t "interactive_heartbeat.overview.create"}}
            {{/if}}
          </button>
        </section>

        <section class="interactive-heartbeat__card">
          <div class="interactive-heartbeat__card-header">
            <div>
              <h2>{{t "interactive_heartbeat.overview.sessions"}}</h2>
              <p>Invitation links are private. Only the two selected members can
                open a session.</p>
            </div>
          </div>

          {{#if this.sessions.length}}
            <div class="interactive-heartbeat__session-list">
              {{#each this.sessions as |session|}}
                <article class="interactive-heartbeat__session-row">
                  <div class="interactive-heartbeat__member">
                    <img src={{session.other_user.user.avatar_url}} alt="" />
                    <div>
                      <strong>{{session.other_user.user.username}}</strong>
                      <span>{{session.status_label}}</span>
                    </div>
                  </div>
                  <div class="interactive-heartbeat__actions">
                    <button
                      type="button"
                      class="btn"
                      {{on "click" (fn this.copyInvite session)}}
                    >
                      {{t "interactive_heartbeat.overview.copy"}}
                    </button>
                    <a class="btn btn-primary" href={{session.href}}>
                      {{t "interactive_heartbeat.overview.open"}}
                    </a>
                  </div>
                </article>
              {{/each}}
            </div>
          {{else}}
            <p class="interactive-heartbeat__muted">{{t
                "interactive_heartbeat.overview.no_sessions"
              }}</p>
          {{/if}}
        </section>
      {{/if}}
    </div>
  </template>
}
