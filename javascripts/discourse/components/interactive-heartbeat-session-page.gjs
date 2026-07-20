import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
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

function loadExternalScript(src) {
  if (window.LovenseBasicSdk) {
    return Promise.resolve();
  }

  return new Promise((resolve, reject) => {
    const existing = document.querySelector(
      `script[data-interactive-heartbeat-sdk="${src}"]`,
    );
    if (existing) {
      if (existing.dataset.loaded === "true") {
        resolve();
        return;
      }
      existing.addEventListener("load", resolve, { once: true });
      existing.addEventListener(
        "error",
        () => reject(new Error("Lovense SDK failed to load.")),
        { once: true },
      );
      return;
    }

    const script = document.createElement("script");
    script.src = src;
    script.async = true;
    script.dataset.interactiveHeartbeatSdk = src;
    script.addEventListener(
      "load",
      () => {
        script.dataset.loaded = "true";
        resolve();
      },
      { once: true },
    );
    script.addEventListener(
      "error",
      () => reject(new Error("Lovense SDK failed to load.")),
      { once: true },
    );
    document.head.appendChild(script);
  });
}

function randomId() {
  return (
    window.crypto?.randomUUID?.() ||
    `${Date.now()}-${Math.random().toString(36).slice(2)}`
  );
}

export default class InteractiveHeartbeatSessionPage extends Component {
  @tracked loading = true;
  @tracked config = null;
  @tracked session = null;
  @tracked error = null;
  @tracked notice = null;
  @tracked saving = false;
  @tracked accepting = false;
  @tracked starting = false;

  @tracked heartbeatConsent = false;
  @tracked toyConsent = false;
  @tracked maxIntensity = 12;
  @tracked pulseStrength = 12;
  @tracked pulseDurationMs = 180;
  @tracked setupDirty = false;

  @tracked lovenseConnecting = false;
  @tracked sdkReady = false;
  @tracked appConnected = false;
  @tracked qrCodeUrl = null;
  @tracked toys = [];
  @tracked selectedToyId = "";
  @tracked currentSignal = null;
  @tracked controlling = false;
  @tracked emergencyStopped = false;

  refreshTimer = null;
  signalTimer = null;
  pulseTimer = null;
  pulseStopTimer = null;
  lockTimer = null;
  sdk = null;
  tabId = randomId();
  controllerLockHeld = false;
  localSignalValidUntil = 0;
  destroyed = false;

  willDestroy() {
    if (super.willDestroy) {
      super.willDestroy(...arguments);
    }
    this.destroyed = true;
    this.cleanup();
  }

  get token() {
    return String(this.args.token || "");
  }

  get current() {
    return this.session?.current_user || null;
  }

  get other() {
    const participant = this.session?.other_user;
    if (!participant?.user) {
      return participant;
    }

    return {
      ...participant,
      user: {
        ...participant.user,
        avatar_url: avatarUrl(participant.user),
      },
    };
  }

  get statusLabel() {
    return this.session?.status
      ? t(`interactive_heartbeat.status.${this.session.status}`)
      : "";
  }

  get invitationPending() {
    return this.session?.status === "invited" && !this.current?.accepted;
  }

  get terminal() {
    return ["declined", "ended", "expired"].includes(this.session?.status);
  }

  get active() {
    return this.session?.status === "active";
  }

  get needsToy() {
    return this.current?.needs_toy_consent === true;
  }

  get needsHeartbeat() {
    return this.current?.needs_heartbeat_consent === true;
  }

  get toySelected() {
    return Boolean(
      this.selectedToyId &&
      this.toys.some((toy) => toy.id === this.selectedToyId),
    );
  }

  get canBecomeReady() {
    if (!this.current?.accepted || this.terminal) {
      return false;
    }
    if (
      this.needsHeartbeat &&
      (!this.heartbeatConsent || this.current?.heartbeat_ready !== true)
    ) {
      return false;
    }
    if (
      this.needsToy &&
      (!this.toyConsent ||
        !this.sdkReady ||
        !this.appConnected ||
        !this.toySelected)
    ) {
      return false;
    }
    return true;
  }

  get canStart() {
    return this.session?.can_start === true && !this.starting;
  }

  get readyButtonDisabled() {
    return !this.current?.ready && !this.canBecomeReady;
  }

  get startButtonDisabled() {
    return !this.canStart;
  }

  get directionRows() {
    const initiator = this.session?.initiator?.username || "Initiator";
    const invitee = this.session?.invitee?.username || "Invitee";
    const directions = this.session?.directions || [];
    const rows = [];
    if (directions.includes("initiator_to_invitee")) {
      rows.push(`${initiator}'s heartbeat → ${invitee}'s toy`);
    }
    if (directions.includes("invitee_to_initiator")) {
      rows.push(`${invitee}'s heartbeat → ${initiator}'s toy`);
    }
    return rows;
  }

  get signalText() {
    if (!this.currentSignal?.active) {
      return "Waiting for a fresh heartbeat signal";
    }

    const source = this.currentSignal.source?.username || "Partner";
    const interval = this.currentSignal.pulse?.interval_ms;
    return `${source}'s heartbeat · pulse every ${interval} ms`;
  }

  get lovenseStatusText() {
    return this.appConnected
      ? t("interactive_heartbeat.lovense.connected")
      : t("interactive_heartbeat.lovense.disconnected");
  }

  get lockKey() {
    return `interactive-heartbeat-controller:${this.token}:${this.config?.current_user?.id || "unknown"}`;
  }

  @action
  async setup() {
    await this.load(true);
    if (!this.destroyed) {
      this.refreshTimer = window.setInterval(() => this.load(false), 3000);
    }
  }

  async load(forceSetup = false) {
    if (forceSetup) {
      this.loading = true;
    }

    try {
      const requests = [
        ajax(`/interactive-heartbeat/api/sessions/${this.token}`),
      ];
      if (!this.config) {
        requests.push(ajax("/interactive-heartbeat/api/config"));
      }
      const [session, config] = await Promise.all(requests);
      if (config) {
        this.config = config;
      }
      this.applySession(session, forceSetup);
      this.error = null;
    } catch (error) {
      this.error = errorMessage(
        error,
        t("interactive_heartbeat.errors.session_load_failed"),
      );
    } finally {
      this.loading = false;
    }
  }

  applySession(session, forceSetup = false) {
    this.session = session;
    if (forceSetup || !this.setupDirty) {
      const current = session?.current_user;
      this.heartbeatConsent = current?.heartbeat_consent === true;
      this.toyConsent = current?.toy_consent === true;
      this.maxIntensity = Number(
        current?.settings?.max_intensity ||
          this.config?.defaults?.max_intensity ||
          12,
      );
      this.pulseStrength = Number(
        current?.settings?.pulse_strength ||
          this.config?.defaults?.pulse_strength ||
          12,
      );
      this.pulseDurationMs = Number(
        current?.settings?.pulse_duration_ms ||
          this.config?.defaults?.pulse_duration_ms ||
          180,
      );
    }

    if (
      session?.status === "active" &&
      session?.current_user?.needs_toy_consent === true
    ) {
      this.startSignalPolling();
    } else {
      this.stopSignalPolling();
    }
  }

  @action
  async acceptSession() {
    this.accepting = true;
    this.error = null;
    try {
      const session = await ajax(
        `/interactive-heartbeat/api/sessions/${this.token}/accept`,
        {
          type: "PUT",
        },
      );
      this.applySession(session, true);
    } catch (error) {
      this.error = errorMessage(
        error,
        t("interactive_heartbeat.errors.update_failed"),
      );
    } finally {
      this.accepting = false;
    }
  }

  @action
  async declineSession() {
    await this.sessionAction("decline");
  }

  @action
  updateHeartbeatConsent(event) {
    this.heartbeatConsent = event.target.checked;
    this.setupDirty = true;
  }

  @action
  updateToyConsent(event) {
    this.toyConsent = event.target.checked;
    this.setupDirty = true;
    if (this.toyConsent) {
      this.emergencyStopped = false;
    } else {
      this.emergencyStopped = true;
      this.clearPulseLoop();
      this.releaseControllerLock();
      void this.stopToyAction();
    }
  }

  @action
  updateMaxIntensity(event) {
    this.maxIntensity = Number(event.target.value);
    this.pulseStrength = Math.min(this.pulseStrength, this.maxIntensity);
    this.setupDirty = true;
  }

  @action
  updatePulseStrength(event) {
    this.pulseStrength = Math.min(
      Number(event.target.value),
      this.maxIntensity,
    );
    this.setupDirty = true;
  }

  @action
  updatePulseDuration(event) {
    this.pulseDurationMs = Number(event.target.value);
    this.setupDirty = true;
  }

  async saveParticipant(ready) {
    this.saving = true;
    this.error = null;
    try {
      const session = await ajax(
        `/interactive-heartbeat/api/sessions/${this.token}/participant`,
        {
          type: "PUT",
          data: {
            heartbeat_consent: this.heartbeatConsent,
            toy_consent: this.toyConsent,
            ready,
            settings: {
              max_intensity: this.maxIntensity,
              pulse_strength: this.pulseStrength,
              pulse_duration_ms: this.pulseDurationMs,
            },
          },
        },
      );
      this.setupDirty = false;
      this.applySession(session, true);
    } catch (error) {
      this.error = errorMessage(
        error,
        t("interactive_heartbeat.errors.update_failed"),
      );
    } finally {
      this.saving = false;
    }
  }

  @action
  async saveSetup() {
    await this.saveParticipant(false);
  }

  @action
  async toggleReady() {
    const ready = !this.current?.ready;
    if (ready && !this.canBecomeReady) {
      this.error = t("interactive_heartbeat.errors.toy_required");
      return;
    }
    if (ready) {
      this.emergencyStopped = false;
    }
    await this.saveParticipant(ready);
  }

  @action
  async startSession() {
    if (!this.canStart) {
      return;
    }
    this.emergencyStopped = false;
    this.starting = true;
    this.error = null;
    try {
      const session = await ajax(
        `/interactive-heartbeat/api/sessions/${this.token}/start`,
        {
          type: "PUT",
        },
      );
      this.applySession(session, true);
    } catch (error) {
      this.error = errorMessage(
        error,
        t("interactive_heartbeat.errors.update_failed"),
      );
    } finally {
      this.starting = false;
    }
  }

  @action
  async pauseSession() {
    await this.sessionAction("pause");
  }

  @action
  async endSession() {
    await this.sessionAction("end");
  }

  async sessionAction(actionName) {
    this.error = null;
    try {
      const session = await ajax(
        `/interactive-heartbeat/api/sessions/${this.token}/${actionName}`,
        {
          type: "PUT",
        },
      );
      this.applySession(session, true);
      await this.stopToyAction();
    } catch (error) {
      this.error = errorMessage(
        error,
        t("interactive_heartbeat.errors.update_failed"),
      );
    }
  }

  @action
  async connectLovense() {
    if (!this.config?.lovense_configured) {
      this.error = t("interactive_heartbeat.lovense.not_configured");
      return;
    }

    this.lovenseConnecting = true;
    this.error = null;
    try {
      const authorization = await ajax(
        "/interactive-heartbeat/api/lovense/token",
        {
          type: "POST",
          data: { session_token: this.token },
        },
      );
      await loadExternalScript(authorization.sdk_url);
      if (typeof window.LovenseBasicSdk !== "function") {
        throw new Error("Lovense SDK is unavailable.");
      }

      this.destroySdk();
      this.sdk = new window.LovenseBasicSdk({
        platform: authorization.platform,
        authToken: authorization.auth_token,
        uid: authorization.uid,
        appType: authorization.app_type,
        debug: false,
      });

      this.sdk.on("ready", async () => {
        this.sdkReady = true;
        this.appConnected = Boolean(this.sdk.getAppStatus?.());
        await this.refreshToys();
        if (!this.appConnected) {
          await this.refreshQrCode();
        }
      });
      this.sdk.on("sdkError", (data) => {
        this.error =
          data?.message || t("interactive_heartbeat.errors.lovense_failed");
      });
      this.sdk.on("appStatusChange", async (status) => {
        this.appConnected = status === true;
        if (this.appConnected) {
          this.qrCodeUrl = null;
          await this.refreshToys();
        } else {
          this.toys = [];
          this.selectedToyId = "";
          await this.handleToyUnavailable();
        }
      });
      this.sdk.on("toyInfoChange", (toyInfo) => this.applyToys(toyInfo));
      this.sdk.on("toyOnlineChange", async (status) => {
        if (!status) {
          this.toys = [];
          this.selectedToyId = "";
          await this.handleToyUnavailable();
        } else {
          await this.refreshToys();
        }
      });
    } catch (error) {
      this.error = errorMessage(
        error,
        t("interactive_heartbeat.errors.lovense_failed"),
      );
    } finally {
      this.lovenseConnecting = false;
    }
  }

  async refreshQrCode() {
    if (!this.sdk?.getQrcode) {
      return;
    }
    const response = await this.sdk.getQrcode();
    this.qrCodeUrl = response?.qrcodeUrl || null;
  }

  @action
  async refreshToys() {
    if (!this.sdk?.getOnlineToys) {
      return;
    }
    const toys = await Promise.resolve(this.sdk.getOnlineToys());
    this.appConnected = Boolean(this.sdk.getAppStatus?.());
    this.applyToys(toys);
  }

  applyToys(toys) {
    this.toys = (Array.isArray(toys) ? toys : [])
      .filter((toy) => toy?.connected !== false)
      .map((toy) => ({
        id: String(toy.id),
        name: toy.nickname || toy.name || toy.toyType || "Lovense toy",
        battery: toy.battery,
      }));

    if (!this.toys.some((toy) => toy.id === this.selectedToyId)) {
      this.selectedToyId = this.toys[0]?.id || "";
    }
  }

  @action
  selectToy(event) {
    this.selectedToyId = event.target.value;
  }

  @action
  connectLovenseApp() {
    this.sdk?.connectLovenseAPP?.();
  }

  @action
  async testToy() {
    if (!this.sdk || !this.toySelected) {
      return;
    }
    try {
      await Promise.resolve(
        this.sdk.sendToyCommand({
          vibrate: Math.min(this.pulseStrength, 5),
          toyId: this.selectedToyId,
        }),
      );
      window.clearTimeout(this.pulseStopTimer);
      this.pulseStopTimer = window.setTimeout(
        () => void this.stopToyAction(),
        600,
      );
    } catch (error) {
      this.error = errorMessage(
        error,
        t("interactive_heartbeat.errors.lovense_failed"),
      );
    }
  }

  async stopToyAction() {
    window.clearTimeout(this.pulseStopTimer);
    this.pulseStopTimer = null;
    this.controlling = false;
    if (!this.sdk?.stopToyAction) {
      return;
    }
    try {
      await Promise.resolve(this.sdk.stopToyAction());
    } catch {
      // Local stopping remains best-effort when the Lovense connection is lost.
    }
  }

  clearPulseLoop() {
    window.clearTimeout(this.pulseTimer);
    this.pulseTimer = null;
    window.clearTimeout(this.pulseStopTimer);
    this.pulseStopTimer = null;
    this.controlling = false;
  }

  @action
  async emergencyStopToy() {
    this.emergencyStopped = true;
    this.localSignalValidUntil = 0;
    this.clearPulseLoop();
    this.releaseControllerLock();
    await this.stopToyAction();
    this.notice = t("interactive_heartbeat.lovense.stopped_and_revoked");

    if (
      this.current?.accepted &&
      this.needsToy &&
      this.toyConsent &&
      !this.terminal
    ) {
      this.toyConsent = false;
      this.setupDirty = true;
      await this.saveParticipant(false);
    }
  }

  async handleToyUnavailable() {
    this.emergencyStopped = true;
    this.localSignalValidUntil = 0;
    this.clearPulseLoop();
    this.releaseControllerLock();
    await this.stopToyAction();

    if (this.active) {
      try {
        const session = await ajax(
          `/interactive-heartbeat/api/sessions/${this.token}/pause`,
          {
            type: "PUT",
          },
        );
        this.applySession(session, true);
      } catch (error) {
        this.error = errorMessage(
          error,
          t("interactive_heartbeat.errors.update_failed"),
        );
      }
    }
  }

  startSignalPolling() {
    if (this.signalTimer) {
      return;
    }
    void this.pollSignal();
    const interval = Number(this.config?.defaults?.signal_poll_ms || 1000);
    this.signalTimer = window.setInterval(
      () => void this.pollSignal(),
      interval,
    );
  }

  stopSignalPolling() {
    window.clearInterval(this.signalTimer);
    this.signalTimer = null;
    this.currentSignal = null;
    this.localSignalValidUntil = 0;
    this.clearPulseLoop();
    void this.stopToyAction();
    this.releaseControllerLock();
  }

  async pollSignal() {
    try {
      const signal = await ajax(
        `/interactive-heartbeat/api/sessions/${this.token}/signal`,
      );
      if (!signal?.active) {
        this.currentSignal = signal;
        this.localSignalValidUntil = 0;
        this.clearPulseLoop();
        await this.stopToyAction();
        return;
      }

      this.currentSignal = signal;
      const validityMs = Math.max(
        Number(signal.expires_at_ms) - Number(signal.server_time_ms),
        0,
      );
      this.localSignalValidUntil = Date.now() + validityMs;
      this.ensurePulseLoop();
    } catch (error) {
      this.currentSignal = null;
      this.localSignalValidUntil = 0;
      await this.stopToyAction();
      if (error?.jqXHR?.status === 404 || error?.jqXHR?.status === 403) {
        this.error = errorMessage(
          error,
          t("interactive_heartbeat.errors.session_load_failed"),
        );
      }
    }
  }

  ensurePulseLoop() {
    if (this.pulseTimer || !this.canControlToy()) {
      return;
    }
    if (!this.acquireControllerLock()) {
      this.error = t("interactive_heartbeat.errors.another_tab");
      return;
    }
    this.pulseTimer = window.setTimeout(() => void this.emitPulse(), 0);
  }

  canControlToy() {
    return Boolean(
      this.active &&
      this.needsToy &&
      this.toyConsent &&
      this.sdkReady &&
      this.appConnected &&
      this.toySelected &&
      this.currentSignal?.active &&
      !this.emergencyStopped &&
      Date.now() < this.localSignalValidUntil,
    );
  }

  async emitPulse() {
    this.pulseTimer = null;
    if (!this.canControlToy() || !this.refreshControllerLock()) {
      await this.stopToyAction();
      return;
    }

    const pulse = this.currentSignal.pulse;
    try {
      await Promise.resolve(
        this.sdk.sendToyCommand({
          vibrate: pulse.strength,
          toyId: this.selectedToyId,
        }),
      );
      this.controlling = true;
      window.clearTimeout(this.pulseStopTimer);
      this.pulseStopTimer = window.setTimeout(
        () => void this.stopToyAction(),
        pulse.duration_ms,
      );
      this.pulseTimer = window.setTimeout(
        () => void this.emitPulse(),
        pulse.interval_ms,
      );
    } catch (error) {
      this.error = errorMessage(
        error,
        t("interactive_heartbeat.errors.lovense_failed"),
      );
      await this.stopToyAction();
      this.releaseControllerLock();
    }
  }

  acquireControllerLock() {
    if (this.controllerLockHeld) {
      return this.refreshControllerLock();
    }

    try {
      const now = Date.now();
      const current = JSON.parse(
        window.localStorage.getItem(this.lockKey) || "null",
      );
      if (
        current?.tabId &&
        current.tabId !== this.tabId &&
        Number(current.expiresAt) > now
      ) {
        return false;
      }

      window.localStorage.setItem(
        this.lockKey,
        JSON.stringify({ tabId: this.tabId, expiresAt: now + 5000 }),
      );
      const verified = JSON.parse(
        window.localStorage.getItem(this.lockKey) || "null",
      );
      this.controllerLockHeld = verified?.tabId === this.tabId;
      if (this.controllerLockHeld && !this.lockTimer) {
        this.lockTimer = window.setInterval(() => {
          if (!this.refreshControllerLock()) {
            this.clearPulseLoop();
            void this.stopToyAction();
          }
        }, 2000);
      }
      return this.controllerLockHeld;
    } catch {
      this.controllerLockHeld = true;
      return true;
    }
  }

  refreshControllerLock() {
    if (!this.controllerLockHeld) {
      return false;
    }
    try {
      const current = JSON.parse(
        window.localStorage.getItem(this.lockKey) || "null",
      );
      if (
        current?.tabId &&
        current.tabId !== this.tabId &&
        Number(current.expiresAt) > Date.now()
      ) {
        this.controllerLockHeld = false;
        return false;
      }
      window.localStorage.setItem(
        this.lockKey,
        JSON.stringify({ tabId: this.tabId, expiresAt: Date.now() + 5000 }),
      );
      return true;
    } catch {
      return true;
    }
  }

  releaseControllerLock() {
    window.clearInterval(this.lockTimer);
    this.lockTimer = null;
    try {
      const current = JSON.parse(
        window.localStorage.getItem(this.lockKey) || "null",
      );
      if (current?.tabId === this.tabId) {
        window.localStorage.removeItem(this.lockKey);
      }
    } catch {
      // Ignore storage restrictions; toy stop remains the primary safety action.
    }
    this.controllerLockHeld = false;
  }

  destroySdk() {
    this.clearPulseLoop();
    this.releaseControllerLock();
    if (!this.sdk) {
      return;
    }
    try {
      this.sdk.stopToyAction?.();
      this.sdk.destroy?.();
    } catch {
      // Best-effort cleanup during provider disconnects.
    }
    this.sdk = null;
    this.sdkReady = false;
    this.appConnected = false;
    this.qrCodeUrl = null;
    this.toys = [];
    this.selectedToyId = "";
  }

  cleanup() {
    window.clearInterval(this.refreshTimer);
    this.refreshTimer = null;
    this.stopSignalPolling();
    window.clearTimeout(this.pulseStopTimer);
    this.pulseStopTimer = null;
    this.destroySdk();
    this.releaseControllerLock();
  }

  <template>
    <div class="interactive-heartbeat" {{didInsert this.setup}}>
      <a class="interactive-heartbeat__back" href="/interactive-heartbeat">
        ←
        {{t "interactive_heartbeat.back"}}
      </a>

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
        <section class="interactive-heartbeat__card">
          <p>{{t "interactive_heartbeat.loading"}}</p>
        </section>
      {{else if this.session}}
        <section
          class="interactive-heartbeat__hero interactive-heartbeat__hero--session"
        >
          <div class="interactive-heartbeat__member">
            {{#if this.other.user.avatar_url}}
              <img src={{this.other.user.avatar_url}} alt="" />
            {{/if}}
            <div>
              <span class="interactive-heartbeat__eyebrow">Private heartbeat
                session</span>
              <h1>You and {{this.other.user.username}}</h1>
              <p>{{this.statusLabel}}</p>
            </div>
          </div>
          {{#if this.active}}
            <span class="interactive-heartbeat__live-pill">Active</span>
          {{/if}}
        </section>

        {{#if this.invitationPending}}
          <section
            class="interactive-heartbeat__card interactive-heartbeat__invitation"
          >
            <h2>{{t "interactive_heartbeat.session.invitation"}}</h2>
            <p>
              Review the requested directions below. Accepting only opens the
              setup; no heartbeat or toy control starts until both members
              separately consent and become ready.
            </p>
            <ul class="interactive-heartbeat__direction-list">
              {{#each this.directionRows as |direction|}}
                <li>{{direction}}</li>
              {{/each}}
            </ul>
            <div class="interactive-heartbeat__actions">
              <button
                type="button"
                class="btn btn-primary"
                {{on "click" this.acceptSession}}
              >
                {{#if this.accepting}}
                  {{t "interactive_heartbeat.session.accepting"}}
                {{else}}
                  {{t "interactive_heartbeat.session.accept"}}
                {{/if}}
              </button>
              <button
                type="button"
                class="btn btn-danger"
                {{on "click" this.declineSession}}
              >
                {{t "interactive_heartbeat.session.decline"}}
              </button>
            </div>
          </section>
        {{else if this.terminal}}
          <section class="interactive-heartbeat__card">
            <h2>{{t "interactive_heartbeat.session.ended"}}</h2>
          </section>
        {{else}}
          <div class="interactive-heartbeat__grid">
            <section class="interactive-heartbeat__card">
              <div class="interactive-heartbeat__card-header">
                <div>
                  <h2>{{t "interactive_heartbeat.session.setup"}}</h2>
                  <p>{{t "interactive_heartbeat.session.exact_bpm_private"}}</p>
                </div>
              </div>

              {{#if this.needsHeartbeat}}
                <label class="interactive-heartbeat__consent">
                  <input
                    type="checkbox"
                    checked={{this.heartbeatConsent}}
                    {{on "change" this.updateHeartbeatConsent}}
                  />
                  <span>{{t
                      "interactive_heartbeat.session.heartbeat_consent"
                    }}</span>
                </label>
              {{/if}}

              {{#if this.needsToy}}
                <label class="interactive-heartbeat__consent">
                  <input
                    type="checkbox"
                    checked={{this.toyConsent}}
                    {{on "change" this.updateToyConsent}}
                  />
                  <span>{{t "interactive_heartbeat.session.toy_consent"}}</span>
                </label>

                <label class="interactive-heartbeat__range-field">
                  <span>{{t "interactive_heartbeat.session.max_intensity"}}:
                    {{this.maxIntensity}}/20</span>
                  <input
                    type="range"
                    min="1"
                    max="20"
                    value={{this.maxIntensity}}
                    {{on "input" this.updateMaxIntensity}}
                  />
                </label>

                <label class="interactive-heartbeat__range-field">
                  <span>{{t "interactive_heartbeat.session.pulse_strength"}}:
                    {{this.pulseStrength}}/20</span>
                  <input
                    type="range"
                    min="1"
                    max={{this.maxIntensity}}
                    value={{this.pulseStrength}}
                    {{on "input" this.updatePulseStrength}}
                  />
                </label>

                <label class="interactive-heartbeat__range-field">
                  <span>{{t "interactive_heartbeat.session.pulse_duration"}}:
                    {{this.pulseDurationMs}}
                    ms</span>
                  <input
                    type="range"
                    min="100"
                    max="500"
                    step="10"
                    value={{this.pulseDurationMs}}
                    {{on "input" this.updatePulseDuration}}
                  />
                </label>
              {{/if}}

              <div class="interactive-heartbeat__actions">
                <button type="button" class="btn" {{on "click" this.saveSetup}}>
                  {{#if this.saving}}
                    {{t "interactive_heartbeat.session.saving"}}
                  {{else}}
                    {{t "interactive_heartbeat.session.save"}}
                  {{/if}}
                </button>
                <button
                  type="button"
                  class="btn btn-primary"
                  disabled={{this.readyButtonDisabled}}
                  {{on "click" this.toggleReady}}
                >
                  {{#if this.current.ready}}
                    {{t "interactive_heartbeat.session.not_ready"}}
                  {{else}}
                    {{t "interactive_heartbeat.session.ready"}}
                  {{/if}}
                </button>
              </div>
            </section>

            {{#if this.needsToy}}
              <section class="interactive-heartbeat__card">
                <div class="interactive-heartbeat__card-header">
                  <div>
                    <h2>{{t "interactive_heartbeat.lovense.title"}}</h2>
                    <p>{{this.lovenseStatusText}}</p>
                  </div>
                </div>

                {{#unless this.sdkReady}}
                  <button
                    type="button"
                    class="btn btn-primary"
                    {{on "click" this.connectLovense}}
                  >
                    {{#if this.lovenseConnecting}}
                      {{t "interactive_heartbeat.lovense.connecting"}}
                    {{else}}
                      {{t "interactive_heartbeat.lovense.connect"}}
                    {{/if}}
                  </button>
                {{/unless}}

                {{#if this.qrCodeUrl}}
                  <div class="interactive-heartbeat__qr">
                    <p>{{t "interactive_heartbeat.lovense.scan"}}</p>
                    <img
                      src={{this.qrCodeUrl}}
                      alt="Lovense connection QR code"
                    />
                    <button
                      type="button"
                      class="btn"
                      {{on "click" this.connectLovenseApp}}
                    >
                      {{t "interactive_heartbeat.lovense.open_app"}}
                    </button>
                  </div>
                {{/if}}

                {{#if this.sdkReady}}
                  <div class="interactive-heartbeat__actions">
                    <button
                      type="button"
                      class="btn"
                      {{on "click" this.refreshToys}}
                    >
                      {{t "interactive_heartbeat.lovense.refresh"}}
                    </button>
                    <button
                      type="button"
                      class="btn btn-danger"
                      {{on "click" this.emergencyStopToy}}
                    >
                      {{t "interactive_heartbeat.lovense.stop"}}
                    </button>
                  </div>
                {{/if}}

                {{#if this.toys.length}}
                  <label class="interactive-heartbeat__field">
                    <span>{{t "interactive_heartbeat.lovense.toy"}}</span>
                    <select
                      value={{this.selectedToyId}}
                      {{on "change" this.selectToy}}
                    >
                      {{#each this.toys as |toy|}}
                        <option value={{toy.id}}>{{toy.name}}{{#if toy.battery}}
                            ·
                            {{toy.battery}}%{{/if}}</option>
                      {{/each}}
                    </select>
                  </label>
                  <button type="button" class="btn" {{on "click" this.testToy}}>
                    {{t "interactive_heartbeat.lovense.test"}}
                  </button>
                {{else if this.sdkReady}}
                  <p class="interactive-heartbeat__muted">{{t
                      "interactive_heartbeat.lovense.no_toys"
                    }}</p>
                {{/if}}
              </section>
            {{/if}}
          </div>

          <section
            class="interactive-heartbeat__card interactive-heartbeat__session-control"
          >
            <div>
              <h2>Session control</h2>
              <p>{{this.signalText}}</p>
              <p class="interactive-heartbeat__muted">{{t
                  "interactive_heartbeat.session.safety"
                }}</p>
            </div>

            <div class="interactive-heartbeat__participants">
              <div>
                <strong>You</strong>
                <span>{{if
                    this.current.accepted
                    "Accepted"
                    "Not accepted"
                  }}</span>
                <span>{{if this.current.ready "Ready" "Not ready"}}</span>
                <span>{{if this.current.present "Present" "Not present"}}</span>
                {{#if this.needsHeartbeat}}
                  <span>{{if
                      this.current.heartbeat_ready
                      "Heartbeat ready"
                      "Heartbeat not ready"
                    }}</span>
                {{/if}}
              </div>
              <div>
                <strong>{{this.other.user.username}}</strong>
                <span>{{if
                    this.other.accepted
                    "Accepted"
                    "Not accepted"
                  }}</span>
                <span>{{if this.other.ready "Ready" "Not ready"}}</span>
                <span>{{if this.other.present "Present" "Not present"}}</span>
                {{#if this.other.needs_heartbeat_consent}}
                  <span>{{if
                      this.other.heartbeat_ready
                      "Heartbeat ready"
                      "Heartbeat not ready"
                    }}</span>
                {{/if}}
              </div>
            </div>

            <div
              class="interactive-heartbeat__actions interactive-heartbeat__actions--critical"
            >
              {{#if this.active}}
                <button
                  type="button"
                  class="btn btn-primary"
                  {{on "click" this.pauseSession}}
                >
                  {{t "interactive_heartbeat.session.pause"}}
                </button>
              {{else}}
                <button
                  type="button"
                  class="btn btn-primary"
                  disabled={{this.startButtonDisabled}}
                  {{on "click" this.startSession}}
                >
                  {{#if this.starting}}
                    {{t "interactive_heartbeat.session.starting"}}
                  {{else}}
                    {{t "interactive_heartbeat.session.start"}}
                  {{/if}}
                </button>
              {{/if}}
              {{#if this.needsToy}}
                <button
                  type="button"
                  class="btn btn-danger"
                  {{on "click" this.emergencyStopToy}}
                >
                  {{t "interactive_heartbeat.lovense.stop"}}
                </button>
              {{/if}}
              <button
                type="button"
                class="btn btn-danger"
                {{on "click" this.endSession}}
              >
                {{t "interactive_heartbeat.session.end"}}
              </button>
            </div>

            {{#unless this.session.can_start}}
              <p class="interactive-heartbeat__muted">{{t
                  "interactive_heartbeat.session.waiting"
                }}</p>
            {{/unless}}
          </section>
        {{/if}}
      {{/if}}
    </div>
  </template>
}
