import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import { scheduleOnce } from "@ember/runloop";
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
  @tracked configurationConsent = true;
  @tracked sessionMode = "cross_heartbeat";
  @tracked leaderUserId = "";
  @tracked configurationDirty = false;

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
    desired_strength: null,
    applied_strength: null,
    current_zone_key: null,
    source_age_ms: null,
    valid_for_ms: 0,
    signals_received: 0,
    transport_errors: 0,
    beats_due: 0,
    browser_beats_skipped_late: 0,
    pattern_cycles_estimated: 0,
    pattern_updates: 0,
    pattern_reuses: 0,
    fallback_pulses_sent: 0,
    commands_skipped_busy: 0,
    command_errors: 0,
    intensity_updates: 0,
    zone_changes_confirmed: 0,
    zone_changes_deferred: 0,
    control_mode: "idle",
    pattern_cycle_ms: null,
    pattern_step_ms: null,
    pattern_on_ms: null,
    pattern_duty_percent: null,
    pattern_run_seconds: null,
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
  activeHeartbeatPattern = null;
  patternRefreshAtMs = 0;
  patternExpiresAtMs = 0;
  signalLossLatched = false;
  signalLossPauseRequested = false;
  loadedConfigurationRevision = null;
  destroyed = false;
  loadInFlight = false;
  pollInFlight = false;
  setupStarted = false;
  lifecycleGeneration = 0;

  constructor(owner, args) {
    super(owner, args);

    // Hydrate all render-critical state before the first template render.
    // This avoids switching a large dynamic tree from loading to loaded while
    // Glimmer is still establishing DOM bounds for the route component.
    this.config = args.initialConfig || null;
    if (args.initialSession) {
      this.applySession(args.initialSession, true, { manageRuntime: false });
      this.loading = false;
    }

    // Timers and signal polling only start after the initial render commits.
    scheduleOnce("afterRender", this, this.setup);
  }

  willDestroy() {
    // Clean up before Glimmer releases the component manager/DOM bounds.
    this.cleanup();
    if (super.willDestroy) {
      super.willDestroy(...arguments);
    }
  }

  isCurrentLifecycle(generation) {
    return !this.destroyed && generation === this.lifecycleGeneration;
  }

  get token() {
    return String(this.args.token || "");
  }

  get current() {
    return this.session?.current_user || null;
  }

  get currentAvatarUrl() {
    return this.current ? avatarUrl(this.current) : null;
  }

  get sessionTitle() {
    const currentUsername = this.current?.username || "You";
    const otherUsername = this.other?.user?.username;
    return otherUsername
      ? `${currentUsername} and ${otherUsername}`
      : currentUsername;
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

  get permissionsGranted() {
    return this.current?.permissions_granted === true;
  }

  get modeApprovalNeeded() {
    return Boolean(
      this.current?.accepted &&
        this.current?.configuration_accepted !== true &&
        !this.terminal,
    );
  }

  get sessionStep() {
    if (this.invitationPending) {
      return "invitation";
    }
    if (!this.permissionsGranted) {
      return "permissions";
    }
    if (this.needsToy && (!this.sdkReady || !this.appConnected || !this.toySelected)) {
      return "connections";
    }
    if (!this.current?.ready || !this.other?.ready) {
      return "ready";
    }
    return this.active ? "active" : "ready";
  }

  get progressSteps() {
    const connectionComplete = Boolean(
      (!this.needsHeartbeat || this.current?.heartbeat_ready === true) &&
        (!this.needsToy ||
          (this.sdkReady && this.appConnected && this.toySelected)),
    );
    const steps = [
      { key: "invitation", complete: this.current?.accepted === true },
      { key: "permissions", complete: this.permissionsGranted },
      { key: "connections", complete: connectionComplete },
      {
        key: "ready",
        complete: this.current?.ready === true && this.other?.ready === true,
      },
      { key: "active", complete: this.active },
    ];
    return steps.map((step) => ({
      ...step,
      label: t(`interactive_heartbeat.session.steps.${step.key}`),
      className: step.complete
        ? "interactive-heartbeat__step interactive-heartbeat__step--complete"
        : this.sessionStep === step.key
          ? "interactive-heartbeat__step interactive-heartbeat__step--current"
          : "interactive-heartbeat__step",
    }));
  }

  get modeApprovalBadges() {
    return [
      {
        key: "current",
        name: this.current?.username || t("interactive_heartbeat.session.mode_you"),
        accepted: this.current?.configuration_accepted === true,
      },
      {
        key: "other",
        name: this.other?.user?.username || "Partner",
        accepted: this.other?.configuration_accepted === true,
      },
    ].map((badge) => ({
      ...badge,
      label: badge.accepted
        ? t("interactive_heartbeat.session.accepted")
        : t("interactive_heartbeat.session.awaiting_acceptance"),
      className: badge.accepted
        ? "interactive-heartbeat__approval-chip interactive-heartbeat__approval-chip--accepted"
        : "interactive-heartbeat__approval-chip interactive-heartbeat__approval-chip--pending",
    }));
  }

  get permissionSummaryRows() {
    const rows = [
      t("interactive_heartbeat.session.permission_heartbeat"),
      t("interactive_heartbeat.session.permission_mode", {
        mode: this.configuredSessionModeLabel,
      }),
    ];
    if (this.needsToy) {
      rows.push(
        t("interactive_heartbeat.session.permission_toy", {
          maximum: this.maxIntensity,
        }),
      );
    }
    return rows;
  }

  get supportsSharedModes() {
    return (
      Array.isArray(this.config?.session_modes) &&
      this.config.session_modes.length > 0
    );
  }

  get supportsResponseModes() {
    return (
      Array.isArray(this.config?.response_modes) &&
      this.config.response_modes.length > 0
    );
  }

  get sessionModeOptions() {
    const modes = this.supportsSharedModes
      ? this.config.session_modes
      : ["cross_heartbeat"];
    return modes.map((value) => ({
      value,
      label: t(`interactive_heartbeat.modes.${value}.label`),
      description: t(`interactive_heartbeat.modes.${value}.description`),
      selected: value === this.sessionMode,
    }));
  }

  get responseModeOptions() {
    const modes = this.supportsResponseModes
      ? this.config.response_modes
      : ["fixed"];
    return modes.map((value) => ({
      value,
      label: t(`interactive_heartbeat.response_modes.${value}.label`),
      selected: value === this.responseMode,
    }));
  }

  get selectedSessionMode() {
    return this.sessionModeOptions.find(
      (option) => option.value === this.sessionMode,
    );
  }

  get selectedSessionModeLabel() {
    return this.selectedSessionMode?.label || this.sessionMode;
  }

  get selectedSessionModeDescription() {
    return this.selectedSessionMode?.description || "";
  }

  get configuredSessionMode() {
    return this.session?.mode || "cross_heartbeat";
  }

  get configuredSessionModeLabel() {
    const option = this.sessionModeOptions.find(
      (item) => item.value === this.configuredSessionMode,
    );
    return option?.label || this.configuredSessionMode;
  }

  get modeRequiresLeader() {
    return this.sessionMode === "leader_follower";
  }

  get canEditConfiguration() {
    return Boolean(this.current?.accepted && !this.terminal);
  }

  get configurationEditDisabled() {
    return !this.canEditConfiguration;
  }

  get configurationSaveDisabled() {
    return (
      !this.canEditConfiguration || !this.configurationDirty || this.saving
    );
  }

  get leaderOptions() {
    return [this.session?.initiator, this.session?.invitee]
      .filter(Boolean)
      .map((user) => ({
        id: String(user.id),
        username: user.username,
        selected: String(user.id) === String(this.leaderUserId),
      }));
  }

  get toyOptions() {
    return this.toys.map((toy) => ({
      ...toy,
      selected: toy.id === this.selectedToyId,
    }));
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

  get modeUsesSyncIntensity() {
    return this.configuredSessionMode === "heart_sync";
  }

  get showMinimumIntensity() {
    return this.modeUsesSyncIntensity || !this.responseIsFixed;
  }

  get showFixedIntensity() {
    return this.responseIsFixed && !this.modeUsesSyncIntensity;
  }

  get showTransitionSettings() {
    return this.modeUsesSyncIntensity || !this.responseIsFixed;
  }

  get toySelected() {
    return Boolean(
      this.selectedToyId &&
      this.toys.some((toy) => toy.id === this.selectedToyId),
    );
  }

  get canBecomeReady() {
    if (!this.current?.accepted || this.terminal || !this.permissionsGranted) {
      return false;
    }
    if (this.needsHeartbeat && this.current?.heartbeat_ready !== true) {
      return false;
    }
    if (
      this.needsToy &&
      (!this.sdkReady || !this.appConnected || !this.toySelected)
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
    const mode = this.sessionMode;
    const selectedLeader = this.leaderOptions.find(
      (option) => option.id === String(this.leaderUserId),
    );
    const leader = selectedLeader?.username || initiator;

    const labelForTarget = (target, partner) => {
      switch (mode) {
        case "shared_control":
          return `${partner}'s heartbeat sets tempo + ${target}'s heartbeat sets intensity → ${target}'s toy`;
        case "heart_sync":
          return `Heartbeat sync between ${initiator} and ${invitee} → ${target}'s toy`;
        case "shared_average":
          return `Average heartbeat of ${initiator} and ${invitee} → ${target}'s toy`;
        case "highest_heartbeat":
          return `Highest live heartbeat → ${target}'s toy`;
        case "lowest_heartbeat":
          return `Lowest live heartbeat → ${target}'s toy`;
        case "leader_follower":
          return `${leader}'s heartbeat as leader → ${target}'s toy`;
        default:
          return `${partner}'s heartbeat → ${target}'s toy`;
      }
    };

    if (directions.includes("initiator_to_invitee")) {
      rows.push(labelForTarget(invitee, initiator));
    }
    if (directions.includes("invitee_to_initiator")) {
      rows.push(labelForTarget(initiator, invitee));
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

  get lastHeartbeatCycleTime() {
    const value = Number(this.signalEngineState?.last_pulse_at_ms);
    return Number.isFinite(value) && value > 0
      ? new Date(value).toLocaleTimeString()
      : "—";
  }

  get lastPatternTime() {
    const value = Number(this.signalEngineState?.last_pattern_at_ms);
    return Number.isFinite(value) && value > 0
      ? new Date(value).toLocaleTimeString()
      : "—";
  }

  get controlModeLabel() {
    const mode = this.signalEngineState?.control_mode || "idle";
    return t(`interactive_heartbeat.signal.mode_${mode}`);
  }

  get patternCycleLabel() {
    const value = Number(this.signalEngineState?.pattern_cycle_ms);
    return Number.isFinite(value) && value > 0 ? Math.round(value) : "—";
  }

  get patternOnTimeLabel() {
    const value = Number(this.signalEngineState?.pattern_on_ms);
    return Number.isFinite(value) && value > 0 ? Math.round(value) : "—";
  }

  get patternStepLabel() {
    const value = Number(this.signalEngineState?.pattern_step_ms);
    return Number.isFinite(value) && value > 0 ? Math.round(value) : "—";
  }

  get patternDutyLabel() {
    const value = Number(this.signalEngineState?.pattern_duty_percent);
    return Number.isFinite(value) && value >= 0 ? Math.round(value) : "—";
  }

  get signalIntervalLabel() {
    const value = Number(this.signalEngineState?.interval_ms);
    return Number.isFinite(value) && value > 0 ? Math.round(value) : "—";
  }

  get desiredStrengthLabel() {
    const value = Number(this.signalEngineState?.desired_strength);
    return Number.isFinite(value) && value > 0 ? Math.round(value) : "—";
  }

  get appliedStrengthLabel() {
    const value = Number(this.signalEngineState?.applied_strength);
    return Number.isFinite(value) && value > 0 ? Math.round(value) : "—";
  }

  get responseModeLabel() {
    const mode =
      this.currentSignal?.response?.mode || this.responseMode || "fixed";
    if (mode === "sync") {
      return t("interactive_heartbeat.response_modes.sync.label");
    }
    return t(`interactive_heartbeat.response_modes.${mode}.label`);
  }

  get syncScoreLabel() {
    const value = Number(this.currentSignal?.control?.sync_score);
    return Number.isFinite(value) ? `${Math.round(value)}%` : "—";
  }

  clearLovenseError() {
    if (this.destroyed) {
      return;
    }

    const previousError = this.lastLovenseError;
    this.lastLovenseError = null;
    if (previousError && this.error === previousError) {
      this.error = null;
    }
  }

  get lovenseStatusText() {
    return this.appConnected
      ? t("interactive_heartbeat.lovense.connected")
      : t("interactive_heartbeat.lovense.disconnected");
  }

  get lockKey() {
    return `interactive-heartbeat-controller:${this.config?.current_user?.id || "unknown"}`;
  }

  setup() {
    if (this.destroyed || this.setupStarted) {
      return;
    }

    this.setupStarted = true;
    this.syncSessionRuntime();

    if (!this.refreshTimer) {
      this.refreshTimer = window.setInterval(() => {
        void this.load(false);
      }, 3000);
    }
  }

  syncSessionRuntime() {
    if (
      this.session?.status === "active" &&
      this.session?.current_user?.needs_toy_consent === true
    ) {
      this.startSignalPolling();
      return;
    }

    const stopReason = this.signalLossLatched
      ? "signal_lost"
      : "session_not_active";
    this.signalLossPauseRequested = false;
    this.stopSignalPolling(stopReason);
    if (stopReason !== "signal_lost") {
      this.signalLossLatched = false;
    }
  }

  async load(forceSetup = false) {
    if (this.destroyed || this.loadInFlight) {
      return;
    }

    const generation = this.lifecycleGeneration;
    this.loadInFlight = true;
    if (forceSetup) {
      this.loading = true;
    }

    try {
      const sessionRequest = ajax(
        `/interactive-heartbeat/api/sessions/${this.token}`,
      );
      const configRequest = this.config
        ? Promise.resolve(null)
        : ajax("/interactive-heartbeat/api/config");
      const [session, config] = await Promise.all([
        sessionRequest,
        configRequest,
      ]);

      if (!this.isCurrentLifecycle(generation)) {
        return;
      }
      if (config) {
        this.config = config;
      }
      this.applySession(session, forceSetup);
      if (this.isCurrentLifecycle(generation)) {
        this.error = null;
      }
    } catch (error) {
      if (this.isCurrentLifecycle(generation)) {
        this.error = errorMessage(
          error,
          t("interactive_heartbeat.errors.session_load_failed"),
        );
      }
    } finally {
      this.loadInFlight = false;
      if (this.isCurrentLifecycle(generation)) {
        this.loading = false;
      }
    }
  }

  applySession(session, forceSetup = false, { manageRuntime = true } = {}) {
    if (this.destroyed || !session) {
      return;
    }
    const revision = Number(session?.configuration?.revision || 1);
    const revisionChanged = this.loadedConfigurationRevision !== revision;
    this.session = session;

    if (forceSetup || !this.configurationDirty || revisionChanged) {
      this.sessionMode = session?.mode || "cross_heartbeat";
      this.leaderUserId = String(
        session?.configuration?.leader_user_id || session?.initiator?.id || "",
      );
      this.configurationConsent = this.supportsSharedModes
        ? session?.current_user?.configuration_accepted === true
        : true;
      this.configurationDirty = false;
      this.loadedConfigurationRevision = revision;
    }

    if (forceSetup || !this.setupDirty) {
      const current = session?.current_user;
      const settings = current?.settings || this.config?.defaults || {};
      this.heartbeatConsent = current?.heartbeat_consent === true;
      this.toyConsent = current?.toy_consent === true;
      this.configurationConsent = this.supportsSharedModes
        ? current?.configuration_accepted === true
        : true;
      this.responseMode = this.supportsResponseModes
        ? String(settings.response_mode || "fixed")
        : "fixed";
      this.maxIntensity = Number(settings.max_intensity || 12);
      this.minIntensity = Number(settings.min_intensity || 3);
      this.pulseStrength = Number(settings.pulse_strength || 12);
      this.pulseDurationMs = Number(settings.pulse_duration_ms || 180);
      this.zoneLowMaxBpm = Number(settings.zone_low_max_bpm || 79);
      this.zoneMediumMaxBpm = Number(settings.zone_medium_max_bpm || 99);
      this.zoneHighMaxBpm = Number(settings.zone_high_max_bpm || 119);
      this.zoneLowIntensity = Number(settings.zone_low_intensity || 3);
      this.zoneMediumIntensity = Number(settings.zone_medium_intensity || 8);
      this.zoneHighIntensity = Number(settings.zone_high_intensity || 11);
      this.zonePeakIntensity = Number(
        settings.zone_peak_intensity || this.maxIntensity,
      );
      this.smoothMinBpm = Number(settings.smooth_min_bpm || 70);
      this.smoothMaxBpm = Number(settings.smooth_max_bpm || 130);
      this.baselineBpm = Number(settings.baseline_bpm || 70);
      this.relativeRangeBpm = Number(settings.relative_range_bpm || 50);
      this.rampUpPerSecond = Number(settings.ramp_up_per_second || 2);
      this.rampDownPerSecond = Number(settings.ramp_down_per_second || 4);
      this.hysteresisBpm = Number(settings.hysteresis_bpm ?? 3);
    }

    if (manageRuntime) {
      this.syncSessionRuntime();
    }
  }

  @action
  async acceptSession() {
    this.accepting = true;
    this.error = null;
    try {
      const session = await ajax(
        `/interactive-heartbeat/api/sessions/${this.token}/join`,
        {
          type: "PUT",
          data: { settings: this.participantSettingsPayload() },
        },
      );
      if (!this.destroyed) {
        this.applySession(session, true);
        this.notice = t("interactive_heartbeat.session.joined_and_allowed");
      }
    } catch (error) {
      if (!this.destroyed) {
        this.error = errorMessage(
          error,
          t("interactive_heartbeat.errors.update_failed"),
        );
      }
    } finally {
      if (!this.destroyed) {
        this.accepting = false;
      }
    }
  }

  participantSettingsPayload() {
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

  @action
  async grantPermissions() {
    this.saving = true;
    this.error = null;
    try {
      const session = await ajax(
        `/interactive-heartbeat/api/sessions/${this.token}/permissions`,
        {
          type: "PUT",
          data: { settings: this.participantSettingsPayload() },
        },
      );
      if (!this.destroyed) {
        this.applySession(session, true);
        this.notice = t("interactive_heartbeat.session.permissions_allowed");
      }
    } catch (error) {
      if (!this.destroyed) {
        this.error = errorMessage(
          error,
          t("interactive_heartbeat.errors.update_failed"),
        );
      }
    } finally {
      if (!this.destroyed) {
        this.saving = false;
      }
    }
  }

  @action
  async revokePermissions() {
    this.saving = true;
    this.error = null;
    this.ensurePulseEngine().stop("consent_revoked", { notifyToy: false });
    await this.stopSelectedToyAction();
    try {
      const session = await ajax(
        `/interactive-heartbeat/api/sessions/${this.token}/permissions/revoke`,
        { type: "PUT" },
      );
      if (!this.destroyed) {
        this.applySession(session, true);
        this.notice = t("interactive_heartbeat.session.permissions_revoked");
      }
    } catch (error) {
      if (!this.destroyed) {
        this.error = errorMessage(
          error,
          t("interactive_heartbeat.errors.update_failed"),
        );
      }
    } finally {
      if (!this.destroyed) {
        this.saving = false;
      }
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
  updateConfigurationConsent(event) {
    this.configurationConsent = event.target.checked;
    this.setupDirty = true;
  }

  @action
  updateSessionMode(event) {
    this.sessionMode = String(event.target.value || "cross_heartbeat");
    if (this.sessionMode === "leader_follower" && !this.leaderUserId) {
      this.leaderUserId = String(this.session?.initiator?.id || "");
    }
    this.configurationDirty = true;
  }

  @action
  updateLeaderUser(event) {
    this.leaderUserId = String(event.target.value || "");
    this.configurationDirty = true;
  }

  @action
  async saveConfiguration() {
    if (this.modeRequiresLeader && !this.leaderUserId) {
      this.error = t("interactive_heartbeat.errors.leader_required");
      return;
    }

    this.saving = true;
    this.error = null;
    try {
      const session = await ajax(
        `/interactive-heartbeat/api/sessions/${this.token}/configuration`,
        {
          type: "PUT",
          data: {
            mode: this.sessionMode,
            leader_user_id: this.modeRequiresLeader ? this.leaderUserId : null,
          },
        },
      );
      if (!this.destroyed) {
        this.configurationDirty = false;
        this.applySession(session, false);
        this.notice = t("interactive_heartbeat.session.mode_proposed");
      }
    } catch (error) {
      if (!this.destroyed) {
        this.error = errorMessage(
          error,
          t("interactive_heartbeat.errors.update_failed"),
        );
      }
    } finally {
      if (!this.destroyed) {
        this.saving = false;
      }
    }
  }

  @action
  updateResponseMode(event) {
    this.responseMode = String(event.target.value || "fixed");
    this.setupDirty = true;
  }

  @action
  updateResponseSetting(event) {
    const key = String(event.target.dataset.setting || "");
    const value = Number(event.target.value);
    if (!Number.isFinite(value)) {
      return;
    }

    switch (key) {
      case "maxIntensity":
        this.maxIntensity = value;
        this.minIntensity = Math.min(this.minIntensity, value);
        this.pulseStrength = Math.min(this.pulseStrength, value);
        this.zoneLowIntensity = Math.min(this.zoneLowIntensity, value);
        this.zoneMediumIntensity = Math.min(this.zoneMediumIntensity, value);
        this.zoneHighIntensity = Math.min(this.zoneHighIntensity, value);
        this.zonePeakIntensity = Math.min(this.zonePeakIntensity, value);
        break;
      case "minIntensity":
        this.minIntensity = Math.min(value, this.maxIntensity);
        this.pulseStrength = Math.max(this.pulseStrength, this.minIntensity);
        this.zoneLowIntensity = Math.max(
          this.zoneLowIntensity,
          this.minIntensity,
        );
        break;
      case "pulseStrength":
        this.pulseStrength = Math.max(
          this.minIntensity,
          Math.min(value, this.maxIntensity),
        );
        break;
      case "pulseDurationMs":
        this.pulseDurationMs = value;
        break;
      case "zoneLowMaxBpm":
        this.zoneLowMaxBpm = value;
        break;
      case "zoneMediumMaxBpm":
        this.zoneMediumMaxBpm = value;
        break;
      case "zoneHighMaxBpm":
        this.zoneHighMaxBpm = value;
        break;
      case "zoneLowIntensity":
        this.zoneLowIntensity = value;
        break;
      case "zoneMediumIntensity":
        this.zoneMediumIntensity = value;
        break;
      case "zoneHighIntensity":
        this.zoneHighIntensity = value;
        break;
      case "zonePeakIntensity":
        this.zonePeakIntensity = value;
        break;
      case "smoothMinBpm":
        this.smoothMinBpm = value;
        break;
      case "smoothMaxBpm":
        this.smoothMaxBpm = value;
        break;
      case "baselineBpm":
        this.baselineBpm = value;
        break;
      case "relativeRangeBpm":
        this.relativeRangeBpm = value;
        break;
      case "rampUpPerSecond":
        this.rampUpPerSecond = value;
        break;
      case "rampDownPerSecond":
        this.rampDownPerSecond = value;
        break;
      case "hysteresisBpm":
        this.hysteresisBpm = value;
        break;
      default:
        return;
    }
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
            configuration_consent: this.configurationConsent,
            ready,
            settings: this.participantSettingsPayload(),
          },
        },
      );
      if (!this.destroyed) {
        this.setupDirty = false;
        this.applySession(session, true);
      }
    } catch (error) {
      if (!this.destroyed) {
        this.error = errorMessage(
          error,
          t("interactive_heartbeat.errors.update_failed"),
        );
      }
    } finally {
      if (!this.destroyed) {
        this.saving = false;
      }
    }
  }

  @action
  async saveSetup() {
    await this.saveParticipant(this.current?.ready === true);
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
      if (!this.destroyed) {
        this.applySession(session, true);
      }
    } catch (error) {
      if (!this.destroyed) {
        this.error = errorMessage(
          error,
          t("interactive_heartbeat.errors.update_failed"),
        );
      }
    } finally {
      if (!this.destroyed) {
        this.starting = false;
      }
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
      if (this.destroyed) {
        return;
      }
      this.applySession(session, true);
      this.ensurePulseEngine().stop(`session_${actionName}`, {
        notifyToy: false,
      });
      await this.stopSelectedToyAction();
    } catch (error) {
      if (!this.destroyed) {
        this.error = errorMessage(
          error,
          t("interactive_heartbeat.errors.update_failed"),
        );
      }
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
      if (this.destroyed) {
        return;
      }

      await loadExternalScript(authorization.sdk_url);
      if (this.destroyed) {
        return;
      }
      if (typeof window.LovenseBasicSdk !== "function") {
        throw new Error("Lovense SDK is unavailable.");
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
        if (this.appConnected) {
          this.clearLovenseError();
        }
        await this.refreshToys();
        if (!this.destroyed && this.sdk === sdk && !this.appConnected) {
          await this.refreshQrCode();
        }
      });
      sdk.on("sdkError", (data) => {
        if (this.destroyed || this.sdk !== sdk) {
          return;
        }
        const message =
          data?.message || t("interactive_heartbeat.errors.lovense_failed");
        this.lastLovenseError = message;
        this.error = message;
      });
      sdk.on("appStatusChange", async (status) => {
        if (this.destroyed || this.sdk !== sdk) {
          return;
        }
        this.appConnected = status === true;
        if (this.appConnected) {
          this.clearLovenseError();
          this.qrCodeUrl = null;
          await this.refreshToys();
        } else {
          this.toys = [];
          this.selectedToyId = "";
          await this.handleToyUnavailable();
        }
      });
      sdk.on("toyInfoChange", (toyInfo) => {
        if (!this.destroyed && this.sdk === sdk) {
          this.applyToys(toyInfo);
        }
      });
      sdk.on("toyOnlineChange", async (status) => {
        if (this.destroyed || this.sdk !== sdk) {
          return;
        }
        if (!status) {
          this.toys = [];
          this.selectedToyId = "";
          await this.handleToyUnavailable();
        } else {
          await this.refreshToys();
        }
      });
    } catch (error) {
      if (!this.destroyed) {
        this.error = errorMessage(
          error,
          t("interactive_heartbeat.errors.lovense_failed"),
        );
        this.lastLovenseError = this.error;
      }
    } finally {
      if (!this.destroyed) {
        this.lovenseConnecting = false;
      }
    }
  }

  async refreshQrCode() {
    const sdk = this.sdk;
    if (!sdk?.getQrcode) {
      return;
    }
    const response = await sdk.getQrcode();
    if (this.destroyed || this.sdk !== sdk) {
      return;
    }
    this.qrCodeUrl = response?.qrcodeUrl || null;
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
    if (this.appConnected && this.toys.length > 0) {
      this.clearLovenseError();
    }
  }

  applyToys(toys) {
    if (this.destroyed) {
      return;
    }
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
    const nextToyId = String(event.target.value || "");
    if (nextToyId === this.selectedToyId) {
      return;
    }

    const previousToyId = this.selectedToyId;
    this.pulseSequence += 1;
    this.resetHeartbeatPatternState();
    if (previousToyId && this.sdk?.stopToyAction) {
      try {
        await this.queueToyCommand(() =>
          this.sdk.stopToyAction({ toyId: previousToyId }),
        );
      } catch {
        // Best-effort stop before moving local control to another toy.
      }
    }
    if (!this.destroyed) {
      this.selectedToyId = nextToyId;
    }
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
      if (this.destroyed || sequence !== this.pulseSequence) {
        return;
      }

      this.controlling = true;
      this.clearLovenseError();
      window.clearTimeout(this.pulseStopTimer);
      this.pulseStopTimer = window.setTimeout(
        () => void this.stopHeartbeatPulse(sequence),
        600,
      );
    } catch (error) {
      if (!this.destroyed) {
        this.error = errorMessage(
          error,
          t("interactive_heartbeat.errors.lovense_failed"),
        );
        this.lastLovenseError = this.error;
      }
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

  resetHeartbeatPatternState() {
    this.activeHeartbeatPattern = null;
    this.patternRefreshAtMs = 0;
    this.patternExpiresAtMs = 0;
  }

  async stopSelectedToyAction({
    invalidatePulse = true,
    toyId = this.selectedToyId,
  } = {}) {
    window.clearTimeout(this.pulseStopTimer);
    this.pulseStopTimer = null;
    if (invalidatePulse) {
      this.pulseSequence += 1;
    }
    this.resetHeartbeatPatternState();
    if (!this.destroyed) {
      this.controlling = false;
    }

    if (!this.sdk?.stopToyAction) {
      return;
    }

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
      !this.destroyed &&
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

  heartbeatControlSettings(pulse) {
    const requestedStrength = Number(pulse?.strength || this.pulseStrength);
    const requestedDuration = Number(
      pulse?.duration_ms || this.pulseDurationMs,
    );

    return {
      strength: Math.max(
        Math.min(
          Number.isFinite(requestedStrength)
            ? requestedStrength
            : this.pulseStrength,
          this.maxIntensity,
          20,
        ),
        1,
      ),
      durationMs: Math.max(
        Math.min(
          Number.isFinite(requestedDuration)
            ? requestedDuration
            : this.pulseDurationMs,
          500,
        ),
        100,
      ),
    };
  }

  async sendHeartbeatPulse(pulse) {
    if (!this.canControlToy() || this.toyCommandQueueDepth > 0) {
      return { status: "busy" };
    }
    if (!this.acquireControllerLock() || !this.refreshControllerLock()) {
      this.error = t("interactive_heartbeat.errors.another_tab");
      return { status: "busy" };
    }

    if (typeof this.sdk?.sendPatternCommand === "function") {
      return this.sendHeartbeatPattern(pulse);
    }

    return this.sendLegacyHeartbeatPulse(pulse);
  }

  async sendHeartbeatPattern(pulse) {
    const { strength, durationMs } = this.heartbeatControlSettings(pulse);
    const nextPattern = {
      ...buildHeartbeatPattern({
        intervalMs: pulse?.interval_ms,
        strength,
        maxIntensity: this.maxIntensity,
        requestedPulseDurationMs: durationMs,
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
      return {
        status: "active",
        mode: "pattern",
        pattern: this.activeHeartbeatPattern,
      };
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
      this.patternExpiresAtMs = acceptedAtMs + nextPattern.run_seconds * 1000;
      this.controlling = true;
      this.clearLovenseError();
      window.clearTimeout(this.pulseStopTimer);
      this.pulseStopTimer = null;

      return {
        status: "updated",
        mode: "pattern",
        pattern: this.activeHeartbeatPattern,
      };
    } catch (error) {
      this.resetHeartbeatPatternState();
      if (!this.destroyed) {
        this.error = errorMessage(
          error,
          t("interactive_heartbeat.errors.lovense_failed"),
        );
        this.lastLovenseError = this.error;
        await this.handleToyUnavailable();
      }
      throw error;
    }
  }

  async sendLegacyHeartbeatPulse(pulse) {
    const sequence = ++this.pulseSequence;
    const { strength, durationMs } = this.heartbeatControlSettings(pulse);

    try {
      await this.queueToyCommand(() =>
        this.sdk.sendToyCommand({
          vibrate: strength,
          toyId: this.selectedToyId,
        }),
      );
      if (sequence !== this.pulseSequence || !this.canControlToy()) {
        return { status: "busy" };
      }

      this.controlling = true;
      this.clearLovenseError();
      window.clearTimeout(this.pulseStopTimer);
      this.pulseStopTimer = window.setTimeout(
        () => void this.stopHeartbeatPulse(sequence),
        durationMs,
      );
      return { status: "sent", mode: "fallback" };
    } catch (error) {
      if (!this.destroyed) {
        this.error = errorMessage(
          error,
          t("interactive_heartbeat.errors.lovense_failed"),
        );
        this.lastLovenseError = this.error;
        await this.handleToyUnavailable();
      }
      throw error;
    }
  }

  @action
  async emergencyStopToy() {
    this.emergencyStopped = true;
    this.ensurePulseEngine().stop("emergency_stop", { notifyToy: false });
    this.releaseControllerLock();
    await this.stopSelectedToyAction();
    if (this.destroyed) {
      return;
    }

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
    if (this.destroyed) {
      return;
    }

    if (this.active) {
      try {
        const session = await ajax(
          `/interactive-heartbeat/api/sessions/${this.token}/pause`,
          {
            type: "PUT",
          },
        );
        if (!this.destroyed) {
          this.applySession(session, true);
        }
      } catch (error) {
        if (!this.destroyed) {
          this.error = errorMessage(
            error,
            t("interactive_heartbeat.errors.update_failed"),
          );
        }
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
      if (!this.destroyed) {
        this.applySession(session, true);
      }
    } catch (error) {
      if (
        !this.destroyed &&
        (error?.jqXHR?.status === 404 || error?.jqXHR?.status === 403)
      ) {
        this.error = errorMessage(
          error,
          t("interactive_heartbeat.errors.session_load_failed"),
        );
      }
    } finally {
      if (!this.destroyed) {
        this.signalLossPauseRequested = false;
      }
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
    if (this.destroyed || this.pollInFlight) {
      return;
    }

    const generation = this.lifecycleGeneration;
    this.pollInFlight = true;
    try {
      const signal = await ajax(
        `/interactive-heartbeat/api/sessions/${this.token}/signal`,
      );
      if (!this.isCurrentLifecycle(generation)) {
        return;
      }

      this.currentSignal = signal;
      if (this.signalLossLatched) {
        void this.pauseForSignalLoss();
        return;
      }
      this.ensurePulseEngine().updateSignal(signal);
    } catch (error) {
      if (!this.isCurrentLifecycle(generation)) {
        return;
      }

      this.ensurePulseEngine().markTransportError();
      if (error?.jqXHR?.status === 404 || error?.jqXHR?.status === 403) {
        this.ensurePulseEngine().stop("session_closed");
        this.error = errorMessage(
          error,
          t("interactive_heartbeat.errors.session_load_failed"),
        );
      }
    } finally {
      this.pollInFlight = false;
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

  destroySdk({ updateTrackedState = true } = {}) {
    this.pulseEngine?.stop("lovense_disconnected", { notifyToy: false });
    window.clearTimeout(this.pulseStopTimer);
    this.pulseStopTimer = null;
    this.pulseSequence += 1;
    this.resetHeartbeatPatternState();
    if (updateTrackedState && !this.destroyed) {
      this.controlling = false;
    }
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
    if (updateTrackedState && !this.destroyed) {
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
    this.lifecycleGeneration += 1;
    window.clearInterval(this.refreshTimer);
    this.refreshTimer = null;
    window.clearInterval(this.signalTimer);
    this.signalTimer = null;
    window.clearTimeout(this.pulseStopTimer);
    this.pulseStopTimer = null;
    this.pulseEngine?.stop("component_destroyed", { notifyToy: false });
    this.destroySdk({ updateTrackedState: false });
    this.pulseEngine?.destroy();
    this.pulseEngine = null;
    this.releaseControllerLock();
  }

  <template>
    <div class="interactive-heartbeat">
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
          <div class="interactive-heartbeat__member interactive-heartbeat__member--session">
            <div class="interactive-heartbeat__member-avatars" aria-hidden="true">
              {{#if this.currentAvatarUrl}}
                <img
                  class="interactive-heartbeat__member-avatar interactive-heartbeat__member-avatar--current"
                  src={{this.currentAvatarUrl}}
                  alt=""
                />
              {{/if}}
              {{#if this.other.user.avatar_url}}
                <img
                  class="interactive-heartbeat__member-avatar interactive-heartbeat__member-avatar--other"
                  src={{this.other.user.avatar_url}}
                  alt=""
                />
              {{/if}}
            </div>
            <div class="interactive-heartbeat__member-copy">
              <span class="interactive-heartbeat__eyebrow">Private heartbeat
                session</span>
              <h1>{{this.sessionTitle}}</h1>
              <p>{{this.statusLabel}}</p>
            </div>
          </div>
          {{#if this.active}}
            <span class="interactive-heartbeat__live-pill">Active</span>
          {{/if}}
        </section>

        <nav class="interactive-heartbeat__progress" aria-label={{t "interactive_heartbeat.session.progress_label"}}>
          <ol>
            {{#each this.progressSteps as |step|}}
              <li class={{step.className}}>
                <span class="interactive-heartbeat__step-marker">{{if step.complete "✓" ""}}</span>
                <span>{{step.label}}</span>
              </li>
            {{/each}}
          </ol>
        </nav>

        {{#if this.invitationPending}}
          <section
            class="interactive-heartbeat__card interactive-heartbeat__invitation"
          >
            <h2>{{t "interactive_heartbeat.session.invitation"}}</h2>
            <p>
              {{t "interactive_heartbeat.session.invitation_simple_help"}}
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
                  {{t "interactive_heartbeat.session.join_and_allow"}}
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
          {{#if this.supportsSharedModes}}
            <section
              class="interactive-heartbeat__card interactive-heartbeat__mode-card"
            >
              <div class="interactive-heartbeat__card-header">
                <div>
                  <h2>{{t "interactive_heartbeat.session.mode_title"}}</h2>
                  <p>{{this.selectedSessionModeDescription}}</p>
                </div>
              </div>

              <div class="interactive-heartbeat__mode-grid">
                <fieldset
                  class="interactive-heartbeat__choice-fieldset"
                  disabled={{this.configurationEditDisabled}}
                >
                  <legend>{{t "interactive_heartbeat.session.mode"}}</legend>
                  <div
                    class="interactive-heartbeat__choice-grid"
                    role="radiogroup"
                    aria-label={{t "interactive_heartbeat.session.mode"}}
                  >
                    {{#each this.sessionModeOptions as |option|}}
                      <label class="interactive-heartbeat__choice">
                        <input
                          type="radio"
                          name="interactive-heartbeat-session-mode"
                          value={{option.value}}
                          checked={{option.selected}}
                          {{on "change" this.updateSessionMode}}
                        />
                        <span class="interactive-heartbeat__choice-content">
                          <strong>{{option.label}}</strong>
                          <small>{{option.description}}</small>
                        </span>
                      </label>
                    {{/each}}
                  </div>
                </fieldset>

                {{#if this.modeRequiresLeader}}
                  <fieldset
                    class="interactive-heartbeat__choice-fieldset"
                    disabled={{this.configurationEditDisabled}}
                  >
                    <legend>{{t
                        "interactive_heartbeat.session.leader"
                      }}</legend>
                    <div
                      class="interactive-heartbeat__choice-grid interactive-heartbeat__choice-grid--compact"
                      role="radiogroup"
                      aria-label={{t "interactive_heartbeat.session.leader"}}
                    >
                      {{#each this.leaderOptions as |option|}}
                        <label class="interactive-heartbeat__choice">
                          <input
                            type="radio"
                            name="interactive-heartbeat-leader"
                            value={{option.id}}
                            checked={{option.selected}}
                            {{on "change" this.updateLeaderUser}}
                          />
                          <span class="interactive-heartbeat__choice-content">
                            <strong>{{option.username}}</strong>
                          </span>
                        </label>
                      {{/each}}
                    </div>
                  </fieldset>
                {{/if}}
              </div>

              <div class="interactive-heartbeat__configuration-status">
                <div class="interactive-heartbeat__configuration-status-header">
                  <strong>{{t "interactive_heartbeat.session.mode_approval_title"}}</strong>
                  <span>{{t "interactive_heartbeat.session.mode_approval_help"}}</span>
                </div>
                <div class="interactive-heartbeat__approval-chip-row">
                  {{#each this.modeApprovalBadges as |badge|}}
                    <span class={{badge.className}}>
                      <strong>{{badge.name}}</strong>
                      <span>{{badge.label}}</span>
                    </span>
                  {{/each}}
                </div>
              </div>

              <div class="interactive-heartbeat__mode-summary">
                <h3>{{t "interactive_heartbeat.session.mode_summary_title"}}</h3>
                <ul class="interactive-heartbeat__direction-list interactive-heartbeat__direction-list--cards">
                  {{#each this.directionRows as |direction|}}
                    <li>{{direction}}</li>
                  {{/each}}
                </ul>
              </div>

              <div class="interactive-heartbeat__actions">
                <button
                  type="button"
                  class="btn btn-primary"
                  disabled={{this.configurationSaveDisabled}}
                  {{on "click" this.saveConfiguration}}
                >
                  {{t "interactive_heartbeat.session.propose_mode"}}
                </button>
                {{#unless this.canEditConfiguration}}
                  <small class="interactive-heartbeat__muted">{{t
                      "interactive_heartbeat.session.mode_waiting_for_acceptance"
                    }}</small>
                {{/unless}}
              </div>
            </section>
          {{/if}}

          <div class="interactive-heartbeat__grid interactive-heartbeat__grid--session">
            <section class="interactive-heartbeat__card">
              <div class="interactive-heartbeat__card-header">
                <div>
                  <h2>{{t "interactive_heartbeat.session.setup"}}</h2>
                  <p>{{t "interactive_heartbeat.session.exact_bpm_private"}}</p>
                </div>
              </div>

              <div class="interactive-heartbeat__permission-summary">
                <div>
                  <h3>{{t "interactive_heartbeat.session.permissions_title"}}</h3>
                  <p>{{t "interactive_heartbeat.session.permissions_scope_help"}}</p>
                  <ul class="interactive-heartbeat__direction-list interactive-heartbeat__direction-list--cards interactive-heartbeat__direction-list--summary">
                    {{#each this.permissionSummaryRows as |row|}}
                      <li>{{row}}</li>
                    {{/each}}
                  </ul>
                </div>
                <div class="interactive-heartbeat__permission-actions">
                  {{#if this.permissionsGranted}}
                    <span class="interactive-heartbeat__permission-status interactive-heartbeat__permission-status--allowed">
                      {{t "interactive_heartbeat.session.permissions_allowed_status"}}
                    </span>
                    <button type="button" class="btn btn-danger" disabled={{this.saving}} {{on "click" this.revokePermissions}}>
                      {{t "interactive_heartbeat.session.withdraw_permissions"}}
                    </button>
                  {{else}}
                    <button type="button" class="btn btn-primary" disabled={{this.saving}} {{on "click" this.grantPermissions}}>
                      {{#if this.modeApprovalNeeded}}
                        {{t "interactive_heartbeat.session.accept_mode_and_allow"}}
                      {{else}}
                        {{t "interactive_heartbeat.session.allow_for_session"}}
                      {{/if}}
                    </button>
                  {{/if}}
                </div>
              </div>

              {{#if this.needsToy}}
                <details class="interactive-heartbeat__advanced-settings">
                  <summary>{{t "interactive_heartbeat.session.advanced_toy_settings"}}</summary>
                  <div class="interactive-heartbeat__advanced-settings-body">
                <fieldset
                  class="interactive-heartbeat__choice-fieldset"
                  disabled={{this.modeUsesSyncIntensity}}
                >
                  <legend>{{t
                      "interactive_heartbeat.session.response_mode"
                    }}</legend>
                  <div
                    class="interactive-heartbeat__choice-grid interactive-heartbeat__choice-grid--compact"
                    role="radiogroup"
                    aria-label={{t
                      "interactive_heartbeat.session.response_mode"
                    }}
                  >
                    {{#each this.responseModeOptions as |option|}}
                      <label class="interactive-heartbeat__choice">
                        <input
                          type="radio"
                          name="interactive-heartbeat-response-mode"
                          value={{option.value}}
                          checked={{option.selected}}
                          {{on "change" this.updateResponseMode}}
                        />
                        <span class="interactive-heartbeat__choice-content">
                          <strong>{{option.label}}</strong>
                        </span>
                      </label>
                    {{/each}}
                  </div>
                </fieldset>

                <div class="interactive-heartbeat__settings-grid">
                  <label class="interactive-heartbeat__range-field">
                    <span>{{t "interactive_heartbeat.session.max_intensity"}}:
                      {{this.maxIntensity}}/20</span>
                    <input
                      type="range"
                      min="1"
                      max="20"
                      value={{this.maxIntensity}}
                      data-setting="maxIntensity"
                      {{on "input" this.updateResponseSetting}}
                    />
                  </label>

                  {{#if this.showMinimumIntensity}}
                    <label class="interactive-heartbeat__range-field">
                      <span>{{t "interactive_heartbeat.session.min_intensity"}}:
                        {{this.minIntensity}}/20</span>
                      <input
                        type="range"
                        min="1"
                        max={{this.maxIntensity}}
                        value={{this.minIntensity}}
                        data-setting="minIntensity"
                        {{on "input" this.updateResponseSetting}}
                      />
                    </label>
                  {{/if}}
                </div>

                {{#if this.modeUsesSyncIntensity}}
                  <p class="interactive-heartbeat__muted">{{t
                      "interactive_heartbeat.session.sync_intensity_help"
                    }}</p>
                {{/if}}

                {{#if this.showFixedIntensity}}
                  <label class="interactive-heartbeat__range-field">
                    <span>{{t "interactive_heartbeat.session.pulse_strength"}}:
                      {{this.pulseStrength}}/20</span>
                    <input
                      type="range"
                      min="1"
                      max={{this.maxIntensity}}
                      value={{this.pulseStrength}}
                      data-setting="pulseStrength"
                      {{on "input" this.updateResponseSetting}}
                    />
                  </label>
                {{/if}}

                {{#if this.responseIsZones}}
                  <fieldset class="interactive-heartbeat__fieldset">
                    <legend>{{t
                        "interactive_heartbeat.session.zone_settings"
                      }}</legend>
                    <div
                      class="interactive-heartbeat__settings-grid interactive-heartbeat__settings-grid--zones"
                    >
                      <label class="interactive-heartbeat__field">
                        <span>{{t
                            "interactive_heartbeat.session.zone_low_max"
                          }}</span>
                        <input
                          type="number"
                          min="45"
                          max="180"
                          value={{this.zoneLowMaxBpm}}
                          data-setting="zoneLowMaxBpm"
                          {{on "change" this.updateResponseSetting}}
                        />
                      </label>
                      <label class="interactive-heartbeat__range-field">
                        <span>{{t
                            "interactive_heartbeat.session.zone_low_intensity"
                          }}:
                          {{this.zoneLowIntensity}}/20</span>
                        <input
                          type="range"
                          min={{this.minIntensity}}
                          max={{this.maxIntensity}}
                          value={{this.zoneLowIntensity}}
                          data-setting="zoneLowIntensity"
                          {{on "input" this.updateResponseSetting}}
                        />
                      </label>
                      <label class="interactive-heartbeat__field">
                        <span>{{t
                            "interactive_heartbeat.session.zone_medium_max"
                          }}</span>
                        <input
                          type="number"
                          min="50"
                          max="200"
                          value={{this.zoneMediumMaxBpm}}
                          data-setting="zoneMediumMaxBpm"
                          {{on "change" this.updateResponseSetting}}
                        />
                      </label>
                      <label class="interactive-heartbeat__range-field">
                        <span>{{t
                            "interactive_heartbeat.session.zone_medium_intensity"
                          }}:
                          {{this.zoneMediumIntensity}}/20</span>
                        <input
                          type="range"
                          min={{this.minIntensity}}
                          max={{this.maxIntensity}}
                          value={{this.zoneMediumIntensity}}
                          data-setting="zoneMediumIntensity"
                          {{on "input" this.updateResponseSetting}}
                        />
                      </label>
                      <label class="interactive-heartbeat__field">
                        <span>{{t
                            "interactive_heartbeat.session.zone_high_max"
                          }}</span>
                        <input
                          type="number"
                          min="55"
                          max="215"
                          value={{this.zoneHighMaxBpm}}
                          data-setting="zoneHighMaxBpm"
                          {{on "change" this.updateResponseSetting}}
                        />
                      </label>
                      <label class="interactive-heartbeat__range-field">
                        <span>{{t
                            "interactive_heartbeat.session.zone_high_intensity"
                          }}:
                          {{this.zoneHighIntensity}}/20</span>
                        <input
                          type="range"
                          min={{this.minIntensity}}
                          max={{this.maxIntensity}}
                          value={{this.zoneHighIntensity}}
                          data-setting="zoneHighIntensity"
                          {{on "input" this.updateResponseSetting}}
                        />
                      </label>
                      <div
                        class="interactive-heartbeat__field interactive-heartbeat__field--spacer"
                      >
                        <span>{{t
                            "interactive_heartbeat.session.zone_peak"
                          }}</span>
                        <small class="interactive-heartbeat__muted">{{t
                            "interactive_heartbeat.session.zone_peak_help"
                          }}</small>
                      </div>
                      <label class="interactive-heartbeat__range-field">
                        <span>{{t
                            "interactive_heartbeat.session.zone_peak_intensity"
                          }}:
                          {{this.zonePeakIntensity}}/20</span>
                        <input
                          type="range"
                          min={{this.minIntensity}}
                          max={{this.maxIntensity}}
                          value={{this.zonePeakIntensity}}
                          data-setting="zonePeakIntensity"
                          {{on "input" this.updateResponseSetting}}
                        />
                      </label>
                    </div>
                    <label class="interactive-heartbeat__range-field">
                      <span>{{t "interactive_heartbeat.session.hysteresis"}}:
                        {{this.hysteresisBpm}}
                        BPM</span>
                      <input
                        type="range"
                        min="0"
                        max="10"
                        value={{this.hysteresisBpm}}
                        data-setting="hysteresisBpm"
                        {{on "input" this.updateResponseSetting}}
                      />
                    </label>
                  </fieldset>
                {{/if}}

                {{#if this.responseIsSmooth}}
                  <fieldset class="interactive-heartbeat__fieldset">
                    <legend>{{t
                        "interactive_heartbeat.session.smooth_settings"
                      }}</legend>
                    <div class="interactive-heartbeat__settings-grid">
                      <label class="interactive-heartbeat__field">
                        <span>{{t
                            "interactive_heartbeat.session.smooth_min_bpm"
                          }}</span>
                        <input
                          type="number"
                          min="40"
                          max="180"
                          value={{this.smoothMinBpm}}
                          data-setting="smoothMinBpm"
                          {{on "change" this.updateResponseSetting}}
                        />
                      </label>
                      <label class="interactive-heartbeat__field">
                        <span>{{t
                            "interactive_heartbeat.session.smooth_max_bpm"
                          }}</span>
                        <input
                          type="number"
                          min="50"
                          max="220"
                          value={{this.smoothMaxBpm}}
                          data-setting="smoothMaxBpm"
                          {{on "change" this.updateResponseSetting}}
                        />
                      </label>
                    </div>
                  </fieldset>
                {{/if}}

                {{#if this.responseIsRelative}}
                  <fieldset class="interactive-heartbeat__fieldset">
                    <legend>{{t
                        "interactive_heartbeat.session.relative_settings"
                      }}</legend>
                    <div class="interactive-heartbeat__settings-grid">
                      <label class="interactive-heartbeat__field">
                        <span>{{t
                            "interactive_heartbeat.session.baseline_bpm"
                          }}</span>
                        <input
                          type="number"
                          min="40"
                          max="180"
                          value={{this.baselineBpm}}
                          data-setting="baselineBpm"
                          {{on "change" this.updateResponseSetting}}
                        />
                      </label>
                      <label class="interactive-heartbeat__field">
                        <span>{{t
                            "interactive_heartbeat.session.relative_range_bpm"
                          }}</span>
                        <input
                          type="number"
                          min="10"
                          max="120"
                          value={{this.relativeRangeBpm}}
                          data-setting="relativeRangeBpm"
                          {{on "change" this.updateResponseSetting}}
                        />
                      </label>
                    </div>
                  </fieldset>
                {{/if}}

                {{#if this.showTransitionSettings}}
                  <fieldset class="interactive-heartbeat__fieldset">
                    <legend>{{t
                        "interactive_heartbeat.session.intensity_transition"
                      }}</legend>
                    <div class="interactive-heartbeat__settings-grid">
                      <label class="interactive-heartbeat__range-field">
                        <span>{{t "interactive_heartbeat.session.ramp_up"}}:
                          {{this.rampUpPerSecond}}/s</span>
                        <input
                          type="range"
                          min="1"
                          max="20"
                          value={{this.rampUpPerSecond}}
                          data-setting="rampUpPerSecond"
                          {{on "input" this.updateResponseSetting}}
                        />
                      </label>
                      <label class="interactive-heartbeat__range-field">
                        <span>{{t "interactive_heartbeat.session.ramp_down"}}:
                          {{this.rampDownPerSecond}}/s</span>
                        <input
                          type="range"
                          min="1"
                          max="20"
                          value={{this.rampDownPerSecond}}
                          data-setting="rampDownPerSecond"
                          {{on "input" this.updateResponseSetting}}
                        />
                      </label>
                    </div>
                  </fieldset>
                {{/if}}

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
                    data-setting="pulseDurationMs"
                    {{on "input" this.updateResponseSetting}}
                  />
                  <small class="interactive-heartbeat__muted">{{t
                      "interactive_heartbeat.session.pulse_duration_help"
                    }}</small>
                </label>
                  </div>
                </details>
              {{/if}}

              <div class="interactive-heartbeat__actions">
                {{#if this.needsToy}}
                <button type="button" class="btn" disabled={{this.saving}} {{on "click" this.saveSetup}}>
                  {{#if this.saving}}
                    {{t "interactive_heartbeat.session.saving"}}
                  {{else}}
                    {{t "interactive_heartbeat.session.save"}}
                  {{/if}}
                </button>
                {{/if}}
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
                  <fieldset class="interactive-heartbeat__choice-fieldset">
                    <legend>{{t "interactive_heartbeat.lovense.toy"}}</legend>
                    <div
                      class="interactive-heartbeat__choice-grid interactive-heartbeat__choice-grid--compact"
                      role="radiogroup"
                      aria-label={{t "interactive_heartbeat.lovense.toy"}}
                    >
                      {{#each this.toyOptions as |toy|}}
                        <label class="interactive-heartbeat__choice">
                          <input
                            type="radio"
                            name="interactive-heartbeat-toy"
                            value={{toy.id}}
                            checked={{toy.selected}}
                            {{on "change" this.selectToy}}
                          />
                          <span class="interactive-heartbeat__choice-content">
                            <strong>{{toy.name}}</strong>
                            {{#if toy.battery}}
                              <small>{{toy.battery}}%</small>
                            {{/if}}
                          </span>
                        </label>
                      {{/each}}
                    </div>
                  </fieldset>
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
                      <dt>{{t
                          "interactive_heartbeat.signal.response_mode"
                        }}</dt>
                      <dd>{{this.responseModeLabel}}</dd>
                    </div>
                    <div>
                      <dt>{{t
                          "interactive_heartbeat.signal.desired_strength"
                        }}</dt>
                      <dd>{{this.desiredStrengthLabel}}/20</dd>
                    </div>
                    <div>
                      <dt>{{t
                          "interactive_heartbeat.signal.applied_strength"
                        }}</dt>
                      <dd>{{this.appliedStrengthLabel}}/20</dd>
                    </div>
                    <div>
                      <dt>{{t "interactive_heartbeat.signal.sync_score"}}</dt>
                      <dd>{{this.syncScoreLabel}}</dd>
                    </div>
                    <div>
                      <dt>{{t "interactive_heartbeat.signal.control_mode"}}</dt>
                      <dd>{{this.controlModeLabel}}</dd>
                    </div>
                    <div>
                      <dt>{{t
                          "interactive_heartbeat.signal.pattern_cycle"
                        }}</dt>
                      <dd>{{this.patternCycleLabel}} ms</dd>
                    </div>
                    <div>
                      <dt>{{t
                          "interactive_heartbeat.signal.pattern_on_time"
                        }}</dt>
                      <dd>{{this.patternOnTimeLabel}} ms</dd>
                    </div>
                    <div>
                      <dt>{{t "interactive_heartbeat.signal.pattern_step"}}</dt>
                      <dd>{{this.patternStepLabel}} ms</dd>
                    </div>
                    <div>
                      <dt>{{t "interactive_heartbeat.signal.pattern_duty"}}</dt>
                      <dd>{{this.patternDutyLabel}}%</dd>
                    </div>
                    <div>
                      <dt>{{t "interactive_heartbeat.signal.last_pattern"}}</dt>
                      <dd>{{this.lastPatternTime}}</dd>
                    </div>
                    <div>
                      <dt>{{t "interactive_heartbeat.signal.last_cycle"}}</dt>
                      <dd>{{this.lastHeartbeatCycleTime}}</dd>
                    </div>
                    <div>
                      <dt>{{t "interactive_heartbeat.signal.updates"}}</dt>
                      <dd>{{this.signalEngineState.signals_received}}</dd>
                    </div>
                    <div>
                      <dt>{{t
                          "interactive_heartbeat.signal.pattern_updates"
                        }}</dt>
                      <dd>{{this.signalEngineState.pattern_updates}}</dd>
                    </div>
                    <div>
                      <dt>{{t
                          "interactive_heartbeat.signal.estimated_cycles"
                        }}</dt>
                      <dd
                      >{{this.signalEngineState.pattern_cycles_estimated}}</dd>
                    </div>
                    <div>
                      <dt>{{t
                          "interactive_heartbeat.signal.intensity_updates"
                        }}</dt>
                      <dd>{{this.signalEngineState.intensity_updates}}</dd>
                    </div>
                    <div>
                      <dt>{{t "interactive_heartbeat.signal.zone_changes"}}</dt>
                      <dd>{{this.signalEngineState.zone_changes_confirmed}}</dd>
                    </div>
                    <div>
                      <dt>{{t
                          "interactive_heartbeat.signal.fallback_pulses"
                        }}</dt>
                      <dd>{{this.signalEngineState.fallback_pulses_sent}}</dd>
                    </div>
                    <div>
                      <dt>{{t
                          "interactive_heartbeat.signal.browser_delays"
                        }}</dt>
                      <dd
                      >{{this.signalEngineState.browser_beats_skipped_late}}</dd>
                    </div>
                    <div>
                      <dt>{{t "interactive_heartbeat.signal.busy_skips"}}</dt>
                      <dd>{{this.signalEngineState.commands_skipped_busy}}</dd>
                    </div>
                    <div>
                      <dt>{{t
                          "interactive_heartbeat.signal.transport_errors"
                        }}</dt>
                      <dd>{{this.signalEngineState.transport_errors}}</dd>
                    </div>
                    <div>
                      <dt>{{t
                          "interactive_heartbeat.signal.command_errors"
                        }}</dt>
                      <dd>{{this.signalEngineState.command_errors}}</dd>
                    </div>
                    <div>
                      <dt>{{t
                          "interactive_heartbeat.signal.last_lovense_error"
                        }}</dt>
                      <dd>{{if
                          this.lastLovenseError
                          this.lastLovenseError
                          "—"
                        }}</dd>
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
                <span>{{if
                    this.current.configuration_accepted
                    "Mode accepted"
                    "Mode approval needed"
                  }}</span>
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
                <span>{{if
                    this.other.configuration_accepted
                    "Mode accepted"
                    "Mode approval needed"
                  }}</span>
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
