import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import { ajax } from "discourse/lib/ajax";
import HeartbeatPulseEngine from "../lib/interactive-heartbeat/pulse-engine";
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
  @tracked signalEngineState = {
    running: false,
    health: "waiting",
    stop_reason: null,
    interval_ms: null,
    source_age_ms: null,
    valid_for_ms: 0,
    signals_received: 0,
    transport_errors: 0,
    pulses_due: 0,
    pulses_sent: 0,
    pulses_skipped_late: 0,
    pulses_skipped_busy: 0,
    pulse_errors: 0,
  };
  @tracked controlling = false;
  @tracked emergencyStopped = false;
  @tracked lastLovenseError = null;

  refreshTimer = null;
  signalTimer = null;
  pulseStopTimer = null;
  lockTimer = null;
  sdk = null;
  tabId = randomId();
  controllerLockHeld = false;
  pulseEngine = null;
  toyCommandChain = Promise.resolve();
  toyCommandQueueDepth = 0;
  pulseSequence = 0;
  signalLossLatched = false;
  signalLossPauseRequested = false;
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
    const health = this.signalEngineState?.health || "waiting";
    const source = this.currentSignal?.source?.username || "Partner";
    const interval = this.signalEngineState?.interval_ms;

    if (health === "live" && interval) {
      return t("interactive_heartbeat.signal.live", { source, interval });
    }
    if (health === "unstable" && interval) {
      return t("interactive_heartbeat.signal.unstable", { source, interval });
    }
    if (health === "lost") {
      return t("interactive_heartbeat.signal.lost");
    }

    return t("interactive_heartbeat.signal.waiting");
  }

  get signalStatusLabel() {
    return t(
      `interactive_heartbeat.signal.status_${this.signalEngineState?.health || "waiting"}`,
    );
  }

  get signalStatusClass() {
    return `interactive-heartbeat__signal-status interactive-heartbeat__signal-status--${
      this.signalEngineState?.health || "waiting"
    }`;
  }

  get signalSourceAgeSeconds() {
    const ageMs = Number(this.signalEngineState?.source_age_ms);
    return Number.isFinite(ageMs) ? Math.max(Math.round(ageMs / 1000), 0) : "—";
  }

  get lastPulseTime() {
    const value = Number(this.signalEngineState?.last_pulse_at_ms);
    return Number.isFinite(value) && value > 0
      ? new Date(value).toLocaleTimeString()
      : "—";
  }

  get signalIntervalLabel() {
    const value = Number(this.signalEngineState?.interval_ms);
    return Number.isFinite(value) && value > 0 ? Math.round(value) : "—";
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
      const stopReason = this.signalLossLatched
        ? "signal_lost"
        : "session_not_active";
      this.signalLossPauseRequested = false;
      this.stopSignalPolling(stopReason);
      if (stopReason !== "signal_lost") {
        this.signalLossLatched = false;
      }
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
      this.ensurePulseEngine().stop("consent_revoked", { notifyToy: false });
      this.releaseControllerLock();
      void this.stopSelectedToyAction();
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
    this.signalLossLatched = false;
    this.signalLossPauseRequested = false;
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
      this.ensurePulseEngine().stop(`session_${actionName}`, { notifyToy: false });
      await this.stopSelectedToyAction();
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
        const message =
          data?.message || t("interactive_heartbeat.errors.lovense_failed");
        this.lastLovenseError = message;
        this.error = message;
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
      this.lastLovenseError = this.error;
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
    if (!this.sdk || !this.toySelected || this.toyCommandQueueDepth > 0) {
      return;
    }

    const sequence = ++this.pulseSequence;
    try {
      await this.queueToyCommand(() =>
        this.sdk.sendToyCommand({
          vibrate: Math.min(this.pulseStrength, 5),
          toyId: this.selectedToyId,
        }),
      );
      this.controlling = true;
      window.clearTimeout(this.pulseStopTimer);
      this.pulseStopTimer = window.setTimeout(
        () => void this.stopHeartbeatPulse(sequence),
        600,
      );
    } catch (error) {
      this.error = errorMessage(
        error,
        t("interactive_heartbeat.errors.lovense_failed"),
      );
      this.lastLovenseError = this.error;
    }
  }

  ensurePulseEngine() {
    if (this.pulseEngine) {
      return this.pulseEngine;
    }

    this.pulseEngine = new HeartbeatPulseEngine({
      onPulse: (pulse) => this.sendHeartbeatPulse(pulse),
      onStop: () => this.stopSelectedToyAction(),
      onStateChange: (state) => {
        if (this.destroyed) {
          return;
        }

        const wasLost = this.signalEngineState?.health === "lost";
        this.signalEngineState = { ...state };
        if (state.health === "lost" && !wasLost && this.active) {
          this.signalLossLatched = true;
          void this.pauseForSignalLoss();
        }
      },
    });
    return this.pulseEngine;
  }

  async queueToyCommand(command) {
    this.toyCommandQueueDepth += 1;
    const operation = this.toyCommandChain.catch(() => {}).then(command);
    this.toyCommandChain = operation.catch(() => {});

    try {
      return await operation;
    } finally {
      this.toyCommandQueueDepth = Math.max(this.toyCommandQueueDepth - 1, 0);
    }
  }

  async stopSelectedToyAction({ invalidatePulse = true } = {}) {
    window.clearTimeout(this.pulseStopTimer);
    this.pulseStopTimer = null;
    if (invalidatePulse) {
      this.pulseSequence += 1;
    }
    this.controlling = false;

    if (!this.sdk?.stopToyAction) {
      return;
    }

    const toyId = this.selectedToyId;
    try {
      await this.queueToyCommand(() =>
        this.sdk.stopToyAction(toyId ? { toyId } : undefined),
      );
    } catch {
      // Local stopping remains best-effort when the Lovense connection is lost.
    }
  }

  async stopHeartbeatPulse(sequence) {
    if (sequence !== this.pulseSequence) {
      return;
    }
    await this.stopSelectedToyAction({ invalidatePulse: false });
  }

  canControlToy() {
    return Boolean(
      this.active &&
      this.needsToy &&
      this.toyConsent &&
      this.sdkReady &&
      this.appConnected &&
      this.toySelected &&
      this.signalEngineState?.running &&
      ["live", "unstable"].includes(this.signalEngineState?.health) &&
      !this.emergencyStopped,
    );
  }

  async sendHeartbeatPulse(pulse) {
    if (!this.canControlToy() || this.toyCommandQueueDepth > 0) {
      return false;
    }
    if (!this.acquireControllerLock() || !this.refreshControllerLock()) {
      this.error = t("interactive_heartbeat.errors.another_tab");
      return false;
    }

    const sequence = ++this.pulseSequence;
    const requestedStrength = Number(pulse?.strength || this.pulseStrength);
    const requestedDuration = Number(
      pulse?.duration_ms || this.pulseDurationMs,
    );
    const strength = Math.max(
      Math.min(
        Number.isFinite(requestedStrength)
          ? requestedStrength
          : this.pulseStrength,
        this.maxIntensity,
        20,
      ),
      1,
    );
    const durationMs = Math.max(
      Math.min(
        Number.isFinite(requestedDuration)
          ? requestedDuration
          : this.pulseDurationMs,
        500,
      ),
      100,
    );

    try {
      await this.queueToyCommand(() =>
        this.sdk.sendToyCommand({
          vibrate: strength,
          toyId: this.selectedToyId,
        }),
      );
      if (sequence !== this.pulseSequence || !this.canControlToy()) {
        return false;
      }

      this.controlling = true;
      window.clearTimeout(this.pulseStopTimer);
      this.pulseStopTimer = window.setTimeout(
        () => void this.stopHeartbeatPulse(sequence),
        durationMs,
      );
      return true;
    } catch (error) {
      this.error = errorMessage(
        error,
        t("interactive_heartbeat.errors.lovense_failed"),
      );
      this.lastLovenseError = this.error;
      await this.handleToyUnavailable();
      throw error;
    }
  }

  @action
  async emergencyStopToy() {
    this.emergencyStopped = true;
    this.ensurePulseEngine().stop("emergency_stop", { notifyToy: false });
    this.releaseControllerLock();
    await this.stopSelectedToyAction();
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
    this.ensurePulseEngine().stop("toy_disconnected", { notifyToy: false });
    this.releaseControllerLock();
    await this.stopSelectedToyAction();

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

  async pauseForSignalLoss() {
    if (this.signalLossPauseRequested || !this.active) {
      return;
    }

    this.signalLossPauseRequested = true;
    try {
      const session = await ajax(
        `/interactive-heartbeat/api/sessions/${this.token}/pause`,
        { type: "PUT" },
      );
      this.applySession(session, true);
    } catch (error) {
      if (error?.jqXHR?.status === 404 || error?.jqXHR?.status === 403) {
        this.error = errorMessage(
          error,
          t("interactive_heartbeat.errors.session_load_failed"),
        );
      }
    } finally {
      this.signalLossPauseRequested = false;
    }
  }

  startSignalPolling() {
    this.ensurePulseEngine();
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

  stopSignalPolling(reason = "session_not_active") {
    window.clearInterval(this.signalTimer);
    this.signalTimer = null;
    this.currentSignal = null;
    this.ensurePulseEngine().stop(reason);
    this.releaseControllerLock();
  }

  async pollSignal() {
    try {
      const signal = await ajax(
        `/interactive-heartbeat/api/sessions/${this.token}/signal`,
      );
      this.currentSignal = signal;
      if (this.signalLossLatched) {
        void this.pauseForSignalLoss();
        return;
      }
      this.ensurePulseEngine().updateSignal(signal);
    } catch (error) {
      this.ensurePulseEngine().markTransportError();
      if (error?.jqXHR?.status === 404 || error?.jqXHR?.status === 403) {
        this.ensurePulseEngine().stop("session_closed");
        this.error = errorMessage(
          error,
          t("interactive_heartbeat.errors.session_load_failed"),
        );
      }
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
            this.ensurePulseEngine().stop("controller_lock_lost", {
              notifyToy: false,
            });
            void this.stopSelectedToyAction();
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
    this.ensurePulseEngine().stop("lovense_disconnected", { notifyToy: false });
    window.clearTimeout(this.pulseStopTimer);
    this.pulseStopTimer = null;
    this.pulseSequence += 1;
    this.controlling = false;
    this.releaseControllerLock();
    if (!this.sdk) {
      return;
    }
    try {
      this.sdk.stopToyAction?.(
        this.selectedToyId ? { toyId: this.selectedToyId } : undefined,
      );
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
    this.pulseEngine?.destroy();
    this.pulseEngine = null;
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
              <div class="interactive-heartbeat__signal-summary">
                <span class={{this.signalStatusClass}}>
                  {{this.signalStatusLabel}}
                </span>
                <p>{{this.signalText}}</p>
              </div>
              <p class="interactive-heartbeat__muted">{{t
                  "interactive_heartbeat.session.safety"
                }}</p>

              {{#if this.needsToy}}
                <details class="interactive-heartbeat__diagnostics">
                  <summary>{{t
                      "interactive_heartbeat.signal.diagnostics_title"
                    }}</summary>
                  <dl>
                    <div>
                      <dt>{{t "interactive_heartbeat.signal.source_age"}}</dt>
                      <dd>{{this.signalSourceAgeSeconds}} s</dd>
                    </div>
                    <div>
                      <dt>{{t "interactive_heartbeat.signal.interval"}}</dt>
                      <dd>{{this.signalIntervalLabel}} ms</dd>
                    </div>
                    <div>
                      <dt>{{t "interactive_heartbeat.signal.last_pulse"}}</dt>
                      <dd>{{this.lastPulseTime}}</dd>
                    </div>
                    <div>
                      <dt>{{t "interactive_heartbeat.signal.updates"}}</dt>
                      <dd>{{this.signalEngineState.signals_received}}</dd>
                    </div>
                    <div>
                      <dt>{{t "interactive_heartbeat.signal.pulses_sent"}}</dt>
                      <dd>{{this.signalEngineState.pulses_sent}}</dd>
                    </div>
                    <div>
                      <dt>{{t "interactive_heartbeat.signal.late_skips"}}</dt>
                      <dd>{{this.signalEngineState.pulses_skipped_late}}</dd>
                    </div>
                    <div>
                      <dt>{{t "interactive_heartbeat.signal.busy_skips"}}</dt>
                      <dd>{{this.signalEngineState.pulses_skipped_busy}}</dd>
                    </div>
                    <div>
                      <dt>{{t
                          "interactive_heartbeat.signal.transport_errors"
                        }}</dt>
                      <dd>{{this.signalEngineState.transport_errors}}</dd>
                    </div>
                    <div>
                      <dt>{{t "interactive_heartbeat.signal.pulse_errors"}}</dt>
                      <dd>{{this.signalEngineState.pulse_errors}}</dd>
                    </div>
                    <div>
                      <dt>{{t
                          "interactive_heartbeat.signal.last_lovense_error"
                        }}</dt>
                      <dd>{{if this.lastLovenseError this.lastLovenseError "—"}}</dd>
                    </div>
                  </dl>
                </details>
              {{/if}}
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
