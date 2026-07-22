import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import { ajax } from "discourse/lib/ajax";
import HeartbeatPulseEngine from "../lib/interactive-heartbeat/pulse-engine";
import {
  buildHeartbeatPattern,
  shouldReplaceHeartbeatPattern,
} from "../lib/interactive-heartbeat/heartbeat-pattern";
import { i18n } from "discourse-i18n";
import { themePrefix } from "virtual:theme";

function t(key, options) {
  return i18n(themePrefix(key), options);
}

function errorMessage(error, fallback) {
  return (
    error?.jqXHR?.responseJSON?.message ||
    error?.responseJSON?.message ||
    error?.message ||
    fallback
  );
}

function randomId() {
  return (
    window.crypto?.randomUUID?.() ||
    `${Date.now()}-${Math.random().toString(36).slice(2)}`
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

export default class InteractiveHeartbeatTestLabPage extends Component {
  @tracked error = null;
  @tracked notice = null;
  @tracked testing = false;
  @tracked signal = null;
  @tracked sourceAKind = "real";
  @tracked sourceABpm = 75;
  @tracked sourceBBpm = 95;
  @tracked sourceBPreset = "fixed";
  @tracked mode = "cross_heartbeat";
  @tracked leaderSource = "A";
  @tracked responseMode = "fixed";
  @tracked maxIntensity = 12;
  @tracked minIntensity = 3;
  @tracked pulseStrength = 12;
  @tracked pulseDurationMs = 180;
  @tracked zoneLowMaxBpm = 79;
  @tracked zoneMediumMaxBpm = 99;
  @tracked zoneHighMaxBpm = 119;
  @tracked zoneLowIntensity = 3;
  @tracked zoneMediumIntensity = 8;
  @tracked zoneHighIntensity = 11;
  @tracked zonePeakIntensity = 12;
  @tracked smoothMinBpm = 70;
  @tracked smoothMaxBpm = 130;
  @tracked baselineBpm = 70;
  @tracked relativeRangeBpm = 50;
  @tracked rampUpPerSecond = 2;
  @tracked rampDownPerSecond = 4;
  @tracked hysteresisBpm = 3;

  @tracked lovenseConnecting = false;
  @tracked sdkReady = false;
  @tracked appConnected = false;
  @tracked qrCodeUrl = null;
  @tracked toys = [];
  @tracked selectedToyId = "";
  @tracked emergencyStopped = false;
  @tracked lastLovenseError = null;
  @tracked engineState = {
    running: false,
    health: "waiting",
    interval_ms: null,
    desired_strength: null,
    applied_strength: null,
    signals_received: 0,
    pattern_updates: 0,
    pattern_reuses: 0,
    fallback_pulses_sent: 0,
    command_errors: 0,
    control_mode: "idle",
    pattern_cycle_ms: null,
    pattern_step_ms: null,
    pattern_on_ms: null,
    pattern_duty_percent: null,
  };

  sdk = null;
  pulseEngine = null;
  signalTimer = null;
  simulationStartedAt = null;
  destroyed = false;
  pollInFlight = false;
  toyCommandChain = Promise.resolve();
  toyCommandQueueDepth = 0;
  pulseSequence = 0;
  pulseStopTimer = null;
  lockTimer = null;
  tabId = randomId();
  controllerLockHeld = false;
  activeHeartbeatPattern = null;
  patternRefreshAtMs = 0;
  patternExpiresAtMs = 0;

  constructor(owner, args) {
    super(owner, args);
    const defaults = args.config?.defaults || {};
    this.maxIntensity = Number(defaults.max_intensity || 12);
    this.minIntensity = Number(defaults.min_intensity || 3);
    this.pulseStrength = Number(defaults.pulse_strength || 12);
    this.pulseDurationMs = Number(defaults.pulse_duration_ms || 180);
  }

  willDestroy() {
    this.cleanup();
    if (super.willDestroy) {
      super.willDestroy(...arguments);
    }
  }

  get config() {
    return this.args.config || {};
  }

  get testLabEnabled() {
    return this.config?.test_lab_enabled === true;
  }

  get sourceAKindOptions() {
    return [
      { value: "real", label: t("interactive_heartbeat.test_lab.real_heartbeat") },
      { value: "simulated", label: t("interactive_heartbeat.test_lab.simulated") },
    ].map((option) => ({
      ...option,
      selected: this.sourceAKind === option.value,
    }));
  }

  get sourceAIsSimulated() {
    return this.sourceAKind === "simulated";
  }

  get leaderOptions() {
    return ["A", "B"].map((value) => ({
      value,
      label: `Source ${value}`,
      selected: this.leaderSource === value,
    }));
  }

  get toyOptions() {
    return this.toys.map((toy) => ({
      ...toy,
      selected: toy.id === this.selectedToyId,
    }));
  }

  get patternCycleLabel() {
    return this.engineState?.pattern_cycle_ms ?? "—";
  }

  get patternOnLabel() {
    return this.engineState?.pattern_on_ms ?? "—";
  }

  get patternRunSecondsLabel() {
    return this.engineState?.pattern_run_seconds ?? "—";
  }

  get patternUpdatesLabel() {
    return this.engineState?.pattern_updates ?? 0;
  }

  get patternReusesLabel() {
    return this.engineState?.pattern_reuses ?? 0;
  }

  get fallbackPulsesLabel() {
    return this.engineState?.fallback_pulses_sent ?? 0;
  }

  get commandErrorsLabel() {
    return this.engineState?.command_errors ?? 0;
  }

  get transportErrorsLabel() {
    return this.engineState?.transport_errors ?? 0;
  }

  get browserDelaysLabel() {
    return this.engineState?.browser_beats_skipped_late ?? 0;
  }

  get modeOptions() {
    const modes = Array.isArray(this.config?.session_modes)
      ? this.config.session_modes
      : ["cross_heartbeat"];
    return modes.map((value) => ({
      value,
      label: t(`interactive_heartbeat.modes.${value}.label`),
      description: t(`interactive_heartbeat.modes.${value}.description`),
      selected: this.mode === value,
    }));
  }

  get responseOptions() {
    const modes = Array.isArray(this.config?.response_modes)
      ? this.config.response_modes
      : ["fixed"];
    return modes.map((value) => ({
      value,
      label: t(`interactive_heartbeat.response_modes.${value}.label`),
      selected: this.responseMode === value,
    }));
  }

  get presetOptions() {
    return ["fixed", "rising", "natural", "spike", "signal_loss"].map(
      (value) => ({
        value,
        label: t(`interactive_heartbeat.test_lab.presets.${value}`),
        selected: this.sourceBPreset === value,
      }),
    );
  }

  get responseIsFixed() {
    return this.responseMode === "fixed";
  }

  get responseIsZones() {
    return this.responseMode === "zones";
  }

  get responseIsSmooth() {
    return this.responseMode === "smooth";
  }

  get responseIsRelative() {
    return this.responseMode === "relative";
  }

  get modeRequiresLeader() {
    return this.mode === "leader_follower";
  }

  get toySelected() {
    return Boolean(
      this.selectedToyId &&
        this.toys.some((toy) => toy.id === this.selectedToyId),
    );
  }

  get lockKey() {
    return `interactive-heartbeat-controller:${this.config?.current_user?.id || "unknown"}`;
  }

  get currentSourceA() {
    return this.signal?.sources?.find((source) => source.key === "A");
  }

  get currentSourceB() {
    return this.signal?.sources?.find((source) => source.key === "B");
  }

  get sourceADisplay() {
    if (this.currentSourceA?.heart_rate) {
      return `${this.currentSourceA.heart_rate} BPM`;
    }
    if (this.sourceAKind === "real") {
      return t("interactive_heartbeat.test_lab.unavailable");
    }
    return `${this.sourceABpm} BPM`;
  }

  get sourceBDisplay() {
    if (this.currentSourceB?.heart_rate) {
      return `${this.currentSourceB.heart_rate} BPM`;
    }
    const source = this.simulatedSourceB();
    return source.available
      ? `${source.bpm} BPM`
      : t("interactive_heartbeat.test_lab.unavailable");
  }

  get previewTempo() {
    return this.signal?.control?.tempo_bpm ?? "—";
  }

  get previewIntensity() {
    return this.signal?.pulse?.desired_strength ?? "—";
  }

  get previewSync() {
    const score = this.signal?.control?.sync_score;
    return Number.isFinite(Number(score)) ? `${Math.round(score)}%` : "—";
  }

  get statusLabel() {
    if (!this.testing) {
      return t("interactive_heartbeat.test_lab.status_stopped");
    }
    if (this.engineState?.health === "live") {
      return t("interactive_heartbeat.test_lab.status_live");
    }
    if (this.engineState?.health === "unstable") {
      return t("interactive_heartbeat.test_lab.status_unstable");
    }
    if (this.engineState?.health === "lost") {
      return t("interactive_heartbeat.test_lab.status_lost");
    }
    return t("interactive_heartbeat.test_lab.status_waiting");
  }

  get controlModeLabel() {
    return t(
      `interactive_heartbeat.signal.mode_${this.engineState?.control_mode || "idle"}`,
    );
  }

  @action
  updateSourceAKind(event) {
    this.sourceAKind = String(event.target.value || "simulated");
  }

  @action
  updateMode(event) {
    this.mode = String(event.target.value || "cross_heartbeat");
  }

  @action
  updateLeader(event) {
    this.leaderSource = String(event.target.value || "A");
  }

  @action
  updatePreset(event) {
    this.sourceBPreset = String(event.target.value || "fixed");
    this.simulationStartedAt = Date.now();
  }

  @action
  updateResponseMode(event) {
    this.responseMode = String(event.target.value || "fixed");
  }

  @action
  updateNumber(event) {
    const key = event.target.dataset.setting;
    if (!key || !(key in this)) {
      return;
    }
    this[key] = Number(event.target.value);
    if (key === "maxIntensity") {
      this.minIntensity = Math.min(this.minIntensity, this.maxIntensity);
      this.pulseStrength = Math.min(this.pulseStrength, this.maxIntensity);
      this.zoneLowIntensity = Math.min(this.zoneLowIntensity, this.maxIntensity);
      this.zoneMediumIntensity = Math.min(
        this.zoneMediumIntensity,
        this.maxIntensity,
      );
      this.zoneHighIntensity = Math.min(this.zoneHighIntensity, this.maxIntensity);
      this.zonePeakIntensity = Math.min(this.zonePeakIntensity, this.maxIntensity);
    }
  }

  @action
  startTest() {
    if (!this.testLabEnabled || this.testing) {
      return;
    }
    this.error = null;
    this.notice = null;
    this.emergencyStopped = false;
    if (this.toySelected && !this.acquireControllerLock()) {
      this.error = t("interactive_heartbeat.errors.another_tab");
      return;
    }
    this.testing = true;
    this.simulationStartedAt = Date.now();
    this.ensurePulseEngine();
    void this.pollSignal();
    this.signalTimer = window.setInterval(() => void this.pollSignal(), 1000);
  }

  @action
  async stopTest() {
    this.testing = false;
    window.clearInterval(this.signalTimer);
    this.signalTimer = null;
    this.signal = null;
    this.ensurePulseEngine().stop("test_stopped", { notifyToy: false });
    await this.stopSelectedToyAction();
    this.releaseControllerLock();
  }

  simulatedSourceB() {
    const elapsed = Math.max(Date.now() - (this.simulationStartedAt || Date.now()), 0);
    const seconds = elapsed / 1000;
    const base = Number(this.sourceBBpm || 95);

    switch (this.sourceBPreset) {
      case "rising": {
        const phase = (seconds % 60) / 60;
        return { bpm: Math.round(base + phase * 40), available: true };
      }
      case "natural":
        return {
          bpm: Math.round(base + Math.sin(seconds / 3) * 4 + Math.sin(seconds) * 2),
          available: true,
        };
      case "spike":
        return {
          bpm: Math.round(base + ((seconds % 30) >= 15 && (seconds % 30) < 22 ? 30 : 0)),
          available: true,
        };
      case "signal_loss":
        return {
          bpm: Math.round(base),
          available: !((seconds % 30) >= 15 && (seconds % 30) < 23),
        };
      default:
        return { bpm: Math.round(base), available: true };
    }
  }

  responseSettings() {
    return {
      response_mode: this.responseMode,
      max_intensity: this.maxIntensity,
      min_intensity: this.minIntensity,
      pulse_strength: this.pulseStrength,
      pulse_duration_ms: this.pulseDurationMs,
      zone_low_max_bpm: this.zoneLowMaxBpm,
      zone_medium_max_bpm: this.zoneMediumMaxBpm,
      zone_high_max_bpm: this.zoneHighMaxBpm,
      zone_low_intensity: this.zoneLowIntensity,
      zone_medium_intensity: this.zoneMediumIntensity,
      zone_high_intensity: this.zoneHighIntensity,
      zone_peak_intensity: this.zonePeakIntensity,
      smooth_min_bpm: this.smoothMinBpm,
      smooth_max_bpm: this.smoothMaxBpm,
      baseline_bpm: this.baselineBpm,
      relative_range_bpm: this.relativeRangeBpm,
      ramp_up_per_second: this.rampUpPerSecond,
      ramp_down_per_second: this.rampDownPerSecond,
      hysteresis_bpm: this.hysteresisBpm,
    };
  }

  async pollSignal() {
    if (!this.testing || this.destroyed || this.pollInFlight) {
      return;
    }

    this.pollInFlight = true;
    const sourceB = this.simulatedSourceB();
    try {
      if (!sourceB.available) {
        this.ensurePulseEngine().markTransportError();
        return;
      }

      const signal = await ajax(
        "/interactive-heartbeat/api/test-lab/signal",
        {
          type: "POST",
          data: {
            test_lab: {
              source_a_kind: this.sourceAKind,
              source_a_bpm: this.sourceABpm,
              source_b_kind: sourceB.available ? "simulated" : "unavailable",
              source_b_bpm: sourceB.bpm,
              mode: this.mode,
              leader_source: this.leaderSource,
              settings: this.responseSettings(),
            },
          },
        },
      );
      if (this.destroyed || !this.testing) {
        return;
      }
      this.signal = signal;
      this.ensurePulseEngine().updateSignal(signal);
    } catch (error) {
      if (!this.destroyed) {
        this.ensurePulseEngine().markTransportError();
        this.error = errorMessage(
          error,
          t("interactive_heartbeat.test_lab.signal_failed"),
        );
      }
    } finally {
      this.pollInFlight = false;
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
        if (!this.destroyed) {
          this.engineState = { ...state };
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

  resetPatternState() {
    this.activeHeartbeatPattern = null;
    this.patternRefreshAtMs = 0;
    this.patternExpiresAtMs = 0;
  }

  canControlToy() {
    return Boolean(
      !this.destroyed &&
        this.testing &&
        this.sdkReady &&
        this.appConnected &&
        this.toySelected &&
        this.engineState?.running &&
        ["live", "unstable"].includes(this.engineState?.health) &&
        !this.emergencyStopped &&
        this.controllerLockHeld,
    );
  }

  async sendHeartbeatPulse(pulse) {
    if (
      !this.sdkReady ||
      !this.appConnected ||
      !this.toySelected ||
      this.emergencyStopped
    ) {
      return { status: "busy" };
    }
    if (!this.controllerLockHeld && !this.acquireControllerLock()) {
      this.error = t("interactive_heartbeat.errors.another_tab");
      return { status: "busy" };
    }
    if (!this.canControlToy() || this.toyCommandQueueDepth > 0) {
      return { status: "busy" };
    }
    if (typeof this.sdk?.sendPatternCommand === "function") {
      return this.sendHeartbeatPattern(pulse);
    }
    return this.sendLegacyPulse(pulse);
  }

  async sendHeartbeatPattern(pulse) {
    const nextPattern = {
      ...buildHeartbeatPattern({
        intervalMs: pulse?.interval_ms,
        strength: pulse?.strength,
        maxIntensity: this.maxIntensity,
        requestedPulseDurationMs: pulse?.duration_ms || this.pulseDurationMs,
      }),
      toy_id: this.selectedToyId,
    };
    const nowMs = Date.now();
    if (
      !shouldReplaceHeartbeatPattern(this.activeHeartbeatPattern, nextPattern, {
        nowMs,
        refreshAtMs: this.patternRefreshAtMs,
      })
    ) {
      return { status: "active", mode: "pattern", pattern: this.activeHeartbeatPattern };
    }

    const sequence = ++this.pulseSequence;
    try {
      await this.queueToyCommand(() =>
        this.sdk.sendPatternCommand({
          strength: nextPattern.strength,
          time: nextPattern.run_seconds,
          interval: nextPattern.interval_ms,
          vibrate: true,
          toyId: this.selectedToyId,
        }),
      );
      if (sequence !== this.pulseSequence || !this.canControlToy()) {
        return { status: "busy" };
      }
      const acceptedAtMs = Date.now();
      this.activeHeartbeatPattern = {
        ...nextPattern,
        updated_at_ms: acceptedAtMs,
      };
      this.patternRefreshAtMs = acceptedAtMs + nextPattern.refresh_after_ms;
      this.patternExpiresAtMs = acceptedAtMs + nextPattern.run_ms;
      this.lastLovenseError = null;
      return { status: "updated", mode: "pattern", pattern: this.activeHeartbeatPattern };
    } catch (error) {
      this.resetPatternState();
      this.lastLovenseError = errorMessage(
        error,
        t("interactive_heartbeat.errors.lovense_failed"),
      );
      this.error = this.lastLovenseError;
      throw error;
    }
  }

  async sendLegacyPulse(pulse) {
    const sequence = ++this.pulseSequence;
    const strength = Math.max(
      Math.min(Number(pulse?.strength || this.pulseStrength), this.maxIntensity, 20),
      1,
    );
    const duration = Math.max(
      Math.min(Number(pulse?.duration_ms || this.pulseDurationMs), 500),
      100,
    );
    await this.queueToyCommand(() =>
      this.sdk.sendToyCommand({ vibrate: strength, toyId: this.selectedToyId }),
    );
    if (sequence !== this.pulseSequence || !this.canControlToy()) {
      return { status: "busy" };
    }
    window.clearTimeout(this.pulseStopTimer);
    this.pulseStopTimer = window.setTimeout(
      () => void this.stopSelectedToyAction({ invalidatePulse: false }),
      duration,
    );
    return { status: "sent", mode: "fallback" };
  }

  async stopSelectedToyAction({ invalidatePulse = true } = {}) {
    window.clearTimeout(this.pulseStopTimer);
    this.pulseStopTimer = null;
    if (invalidatePulse) {
      this.pulseSequence += 1;
    }
    this.resetPatternState();
    if (!this.sdk?.stopToyAction) {
      return;
    }
    try {
      await this.queueToyCommand(() =>
        this.sdk.stopToyAction(
          this.selectedToyId ? { toyId: this.selectedToyId } : undefined,
        ),
      );
    } catch {
      // Best-effort safety stop.
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
        "/interactive-heartbeat/api/test-lab/lovense/token",
        { type: "POST" },
      );
      await loadExternalScript(authorization.sdk_url);
      if (this.destroyed || typeof window.LovenseBasicSdk !== "function") {
        return;
      }
      this.destroySdk();
      const sdk = new window.LovenseBasicSdk({
        platform: authorization.platform,
        authToken: authorization.auth_token,
        uid: authorization.uid,
        appType: authorization.app_type,
        debug: false,
      });
      this.sdk = sdk;
      sdk.on("ready", async () => {
        if (this.destroyed || this.sdk !== sdk) {
          return;
        }
        this.sdkReady = true;
        this.appConnected = Boolean(sdk.getAppStatus?.());
        await this.refreshToys();
        if (!this.appConnected) {
          await this.refreshQrCode();
        }
      });
      sdk.on("sdkError", (data) => {
        if (!this.destroyed && this.sdk === sdk) {
          this.lastLovenseError =
            data?.message || t("interactive_heartbeat.errors.lovense_failed");
          this.error = this.lastLovenseError;
        }
      });
      sdk.on("appStatusChange", async (status) => {
        if (this.destroyed || this.sdk !== sdk) {
          return;
        }
        this.appConnected = status === true;
        if (this.appConnected) {
          this.qrCodeUrl = null;
          this.lastLovenseError = null;
          await this.refreshToys();
        } else {
          this.toys = [];
          this.selectedToyId = "";
          await this.stopSelectedToyAction();
        }
      });
      sdk.on("toyInfoChange", (toys) => {
        if (!this.destroyed && this.sdk === sdk) {
          this.applyToys(toys);
        }
      });
      sdk.on("toyOnlineChange", async (status) => {
        if (this.destroyed || this.sdk !== sdk) {
          return;
        }
        if (status) {
          await this.refreshToys();
        } else {
          this.toys = [];
          this.selectedToyId = "";
          await this.stopSelectedToyAction();
        }
      });
    } catch (error) {
      if (!this.destroyed) {
        this.error = errorMessage(
          error,
          t("interactive_heartbeat.errors.lovense_failed"),
        );
      }
    } finally {
      if (!this.destroyed) {
        this.lovenseConnecting = false;
      }
    }
  }

  async refreshQrCode() {
    const sdk = this.sdk;
    const response = await sdk?.getQrcode?.();
    if (!this.destroyed && this.sdk === sdk) {
      this.qrCodeUrl = response?.qrcodeUrl || null;
    }
  }

  @action
  connectLovenseApp() {
    this.sdk?.connectLovenseAPP?.();
  }

  @action
  async refreshToys() {
    const sdk = this.sdk;
    if (!sdk?.getOnlineToys) {
      return;
    }
    const toys = await Promise.resolve(sdk.getOnlineToys());
    if (this.destroyed || this.sdk !== sdk) {
      return;
    }
    this.appConnected = Boolean(sdk.getAppStatus?.());
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
  async selectToy(event) {
    const next = String(event.target.value || "");
    if (next === this.selectedToyId) {
      return;
    }
    await this.stopSelectedToyAction();
    this.selectedToyId = next;
  }

  @action
  async emergencyStop() {
    this.emergencyStopped = true;
    this.testing = false;
    window.clearInterval(this.signalTimer);
    this.signalTimer = null;
    this.ensurePulseEngine().stop("emergency_stop", { notifyToy: false });
    await this.stopSelectedToyAction();
    this.releaseControllerLock();
    this.notice = t("interactive_heartbeat.test_lab.emergency_stopped");
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
        JSON.stringify({
          tabId: this.tabId,
          expiresAt: Date.now() + 5000,
        }),
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
      // Local storage may be restricted; the toy stop remains the safety action.
    }
    this.controllerLockHeld = false;
  }

  destroySdk() {
    this.ensurePulseEngine().stop("lovense_disconnected", { notifyToy: false });
    void this.stopSelectedToyAction();
    try {
      this.sdk?.destroy?.();
    } catch {
      // Best-effort cleanup.
    }
    this.sdk = null;
    this.releaseControllerLock();
    if (!this.destroyed) {
      this.sdkReady = false;
      this.appConnected = false;
      this.qrCodeUrl = null;
      this.toys = [];
      this.selectedToyId = "";
    }
  }

  cleanup() {
    if (this.destroyed) {
      return;
    }
    this.destroyed = true;
    window.clearInterval(this.signalTimer);
    window.clearTimeout(this.pulseStopTimer);
    this.signalTimer = null;
    this.pulseStopTimer = null;
    this.pulseEngine?.stop("component_destroyed", { notifyToy: false });
    try {
      this.sdk?.stopToyAction?.(
        this.selectedToyId ? { toyId: this.selectedToyId } : undefined,
      );
      this.sdk?.destroy?.();
    } catch {
      // Best-effort cleanup.
    }
    this.sdk = null;
    this.releaseControllerLock();
    this.pulseEngine?.destroy();
    this.pulseEngine = null;
  }

  <template>
    <div class="interactive-heartbeat interactive-heartbeat--test-lab">
      <a class="interactive-heartbeat__back" href="/interactive-heartbeat">
        ← {{t "interactive_heartbeat.back"}}
      </a>

      <section class="interactive-heartbeat__hero">
        <div>
          <span class="interactive-heartbeat__eyebrow">Admin only</span>
          <h1>{{t "interactive_heartbeat.test_lab.title"}}</h1>
          <p>{{t "interactive_heartbeat.test_lab.subtitle"}}</p>
        </div>
      </section>

      {{#if this.error}}
        <div class="interactive-heartbeat__alert interactive-heartbeat__alert--error" role="alert">
          {{this.error}}
        </div>
      {{/if}}
      {{#if this.notice}}
        <div class="interactive-heartbeat__alert interactive-heartbeat__alert--success" role="status">
          {{this.notice}}
        </div>
      {{/if}}

      {{#if this.testLabEnabled}}
        <section class="interactive-heartbeat__card">
          <div class="interactive-heartbeat__card-header">
            <div>
              <h2>{{t "interactive_heartbeat.test_lab.sources_title"}}</h2>
              <p>{{t "interactive_heartbeat.test_lab.sources_help"}}</p>
            </div>
          </div>

          <div class="interactive-heartbeat__test-grid">
            <div>
              <h3>Source A</h3>
              <div class="interactive-heartbeat__choice-grid interactive-heartbeat__choice-grid--compact interactive-heartbeat__choice-grid--stacked">
                {{#each this.sourceAKindOptions as |option|}}
                  <label class="interactive-heartbeat__choice">
                    <input type="radio" name="test-source-a" value={{option.value}} checked={{option.selected}} {{on "change" this.updateSourceAKind}} />
                    <span class="interactive-heartbeat__choice-content"><strong>{{option.label}}</strong></span>
                  </label>
                {{/each}}
              </div>
              {{#if this.sourceAIsSimulated}}
                <label class="interactive-heartbeat__range-field">
                  <span>A: {{this.sourceABpm}} BPM</span>
                  <input type="range" min="30" max="220" value={{this.sourceABpm}} data-setting="sourceABpm" {{on "input" this.updateNumber}} />
                </label>
              {{/if}}
            </div>

            <div>
              <h3>Source B</h3>
              <label class="interactive-heartbeat__range-field">
                <span>Base: {{this.sourceBBpm}} BPM</span>
                <input type="range" min="30" max="180" value={{this.sourceBBpm}} data-setting="sourceBBpm" {{on "input" this.updateNumber}} />
              </label>
              <div class="interactive-heartbeat__choice-grid interactive-heartbeat__choice-grid--compact">
                {{#each this.presetOptions as |option|}}
                  <label class="interactive-heartbeat__choice">
                    <input type="radio" name="test-source-b-preset" value={{option.value}} checked={{option.selected}} {{on "change" this.updatePreset}} />
                    <span class="interactive-heartbeat__choice-content"><strong>{{option.label}}</strong></span>
                  </label>
                {{/each}}
              </div>
            </div>
          </div>
        </section>

        <section class="interactive-heartbeat__card">
          <div class="interactive-heartbeat__card-header">
            <div><h2>{{t "interactive_heartbeat.test_lab.mode_title"}}</h2></div>
          </div>
          <div class="interactive-heartbeat__choice-grid">
            {{#each this.modeOptions as |option|}}
              <label class="interactive-heartbeat__choice">
                <input type="radio" name="test-session-mode" value={{option.value}} checked={{option.selected}} {{on "change" this.updateMode}} />
                <span class="interactive-heartbeat__choice-content"><strong>{{option.label}}</strong><small>{{option.description}}</small></span>
              </label>
            {{/each}}
          </div>
          {{#if this.modeRequiresLeader}}
            <div class="interactive-heartbeat__choice-grid interactive-heartbeat__choice-grid--compact">
              {{#each this.leaderOptions as |option|}}
                <label class="interactive-heartbeat__choice">
                  <input type="radio" name="test-leader" value={{option.value}} checked={{option.selected}} {{on "change" this.updateLeader}} />
                  <span class="interactive-heartbeat__choice-content"><strong>{{option.label}}</strong></span>
                </label>
              {{/each}}
            </div>
          {{/if}}
        </section>

        <section class="interactive-heartbeat__card interactive-heartbeat__test-response-card">
          <div class="interactive-heartbeat__card-header"><div><h2>{{t "interactive_heartbeat.test_lab.response_title"}}</h2></div></div>
          <div class="interactive-heartbeat__choice-grid interactive-heartbeat__choice-grid--compact">
            {{#each this.responseOptions as |option|}}
              <label class="interactive-heartbeat__choice">
                <input type="radio" name="test-response-mode" value={{option.value}} checked={{option.selected}} {{on "change" this.updateResponseMode}} />
                <span class="interactive-heartbeat__choice-content"><strong>{{option.label}}</strong></span>
              </label>
            {{/each}}
          </div>
          <div class="interactive-heartbeat__settings-grid">
            <label class="interactive-heartbeat__range-field"><span>Maximum: {{this.maxIntensity}}/20</span><input type="range" min="1" max="20" value={{this.maxIntensity}} data-setting="maxIntensity" {{on "input" this.updateNumber}} /></label>
            <label class="interactive-heartbeat__range-field"><span>Minimum: {{this.minIntensity}}/20</span><input type="range" min="1" max={{this.maxIntensity}} value={{this.minIntensity}} data-setting="minIntensity" {{on "input" this.updateNumber}} /></label>
          </div>
          {{#if this.responseIsFixed}}
            <label class="interactive-heartbeat__range-field"><span>Fixed intensity: {{this.pulseStrength}}/20</span><input type="range" min="1" max={{this.maxIntensity}} value={{this.pulseStrength}} data-setting="pulseStrength" {{on "input" this.updateNumber}} /></label>
          {{/if}}
          {{#if this.responseIsSmooth}}
            <div class="interactive-heartbeat__settings-grid">
              <label class="interactive-heartbeat__field"><span>Minimum BPM</span><input type="number" min="40" max="180" value={{this.smoothMinBpm}} data-setting="smoothMinBpm" {{on "change" this.updateNumber}} /></label>
              <label class="interactive-heartbeat__field"><span>Maximum BPM</span><input type="number" min="50" max="220" value={{this.smoothMaxBpm}} data-setting="smoothMaxBpm" {{on "change" this.updateNumber}} /></label>
            </div>
          {{/if}}
          {{#if this.responseIsRelative}}
            <div class="interactive-heartbeat__settings-grid">
              <label class="interactive-heartbeat__field"><span>Baseline BPM</span><input type="number" min="40" max="180" value={{this.baselineBpm}} data-setting="baselineBpm" {{on "change" this.updateNumber}} /></label>
              <label class="interactive-heartbeat__field"><span>Range above baseline</span><input type="number" min="10" max="120" value={{this.relativeRangeBpm}} data-setting="relativeRangeBpm" {{on "change" this.updateNumber}} /></label>
            </div>
          {{/if}}
          {{#if this.responseIsZones}}
            <p class="interactive-heartbeat__muted">Zone defaults are used: ≤79, ≤99, ≤119 and peak.</p>
          {{/if}}
          <label class="interactive-heartbeat__range-field"><span>Pulse duration: {{this.pulseDurationMs}} ms</span><input type="range" min="100" max="500" step="10" value={{this.pulseDurationMs}} data-setting="pulseDurationMs" {{on "input" this.updateNumber}} /></label>
        </section>

        <section class="interactive-heartbeat__card interactive-heartbeat__test-preview">
          <div class="interactive-heartbeat__card-header"><div><h2>{{t "interactive_heartbeat.test_lab.preview_title"}}</h2><p>{{this.statusLabel}}</p></div></div>
          <div class="interactive-heartbeat__diagnostics-grid">
            <div><span>Source A</span><strong>{{this.sourceADisplay}}</strong></div>
            <div><span>Source B</span><strong>{{this.sourceBDisplay}}</strong></div>
            <div><span>Calculated tempo</span><strong>{{this.previewTempo}} BPM</strong></div>
            <div><span>Calculated intensity</span><strong>{{this.previewIntensity}}/20</strong></div>
            <div><span>Sync score</span><strong>{{this.previewSync}}</strong></div>
            <div><span>Toy control</span><strong>{{this.controlModeLabel}}</strong></div>
          </div>
          <div class="interactive-heartbeat__actions">
            {{#if this.testing}}
              <button type="button" class="btn" {{on "click" this.stopTest}}>{{t "interactive_heartbeat.test_lab.stop"}}</button>
            {{else}}
              <button type="button" class="btn btn-primary" {{on "click" this.startTest}}>{{t "interactive_heartbeat.test_lab.start"}}</button>
            {{/if}}
            <button type="button" class="btn btn-danger" {{on "click" this.emergencyStop}}>{{t "interactive_heartbeat.lovense.stop"}}</button>
          </div>
        </section>

        <section class="interactive-heartbeat__card">
          <div class="interactive-heartbeat__card-header"><div><h2>{{t "interactive_heartbeat.lovense.title"}}</h2><p>{{if this.appConnected (t "interactive_heartbeat.lovense.connected") (t "interactive_heartbeat.lovense.disconnected")}}</p></div></div>
          {{#unless this.sdkReady}}
            <button type="button" class="btn btn-primary" {{on "click" this.connectLovense}}>{{if this.lovenseConnecting (t "interactive_heartbeat.lovense.connecting") (t "interactive_heartbeat.lovense.connect")}}</button>
          {{/unless}}
          {{#if this.qrCodeUrl}}
            <div class="interactive-heartbeat__qr"><p>{{t "interactive_heartbeat.lovense.scan"}}</p><img src={{this.qrCodeUrl}} alt="Lovense connection QR code" /><button type="button" class="btn" {{on "click" this.connectLovenseApp}}>{{t "interactive_heartbeat.lovense.open_app"}}</button></div>
          {{/if}}
          {{#if this.sdkReady}}
            <div class="interactive-heartbeat__actions"><button type="button" class="btn" {{on "click" this.refreshToys}}>{{t "interactive_heartbeat.lovense.refresh"}}</button></div>
            {{#if this.toys.length}}
              <div class="interactive-heartbeat__choice-grid interactive-heartbeat__choice-grid--compact">
                {{#each this.toyOptions as |toy|}}
                  <label class="interactive-heartbeat__choice"><input type="radio" name="test-toy" value={{toy.id}} checked={{toy.selected}} {{on "change" this.selectToy}} /><span class="interactive-heartbeat__choice-content"><strong>{{toy.name}}</strong>{{#if toy.battery}}<small>{{toy.battery}}%</small>{{/if}}</span></label>
                {{/each}}
              </div>
            {{else}}
              <p class="interactive-heartbeat__muted">{{t "interactive_heartbeat.lovense.no_toys"}}</p>
            {{/if}}
          {{/if}}
        </section>

        <details class="interactive-heartbeat__card interactive-heartbeat__diagnostics">
          <summary>{{t "interactive_heartbeat.signal.diagnostics_title"}}</summary>
          <div class="interactive-heartbeat__diagnostics-grid">
            <div><span>Pattern cycle</span><strong>{{this.patternCycleLabel}} ms</strong></div>
            <div><span>Pattern on time</span><strong>{{this.patternOnLabel}} ms</strong></div>
            <div><span>Pattern run time</span><strong>{{this.patternRunSecondsLabel}} s</strong></div>
            <div><span>Pattern updates</span><strong>{{this.patternUpdatesLabel}}</strong></div>
            <div><span>Pattern reuses</span><strong>{{this.patternReusesLabel}}</strong></div>
            <div><span>Fallback pulses</span><strong>{{this.fallbackPulsesLabel}}</strong></div>
            <div><span>Browser timing delays</span><strong>{{this.browserDelaysLabel}}</strong></div>
            <div><span>Signal transport gaps</span><strong>{{this.transportErrorsLabel}}</strong></div>
            <div><span>Command errors</span><strong>{{this.commandErrorsLabel}}</strong></div>
          </div>
        </details>
      {{/if}}
    </div>
  </template>
}
