const DEFAULT_INTERVAL_MS = 750;
const MIN_INTERVAL_MS = 273;
const MAX_INTERVAL_MS = 2000;
const MIN_VALIDITY_MS = 250;
const SMOOTHING_FACTOR = 0.35;
const MAX_INTERVAL_STEP_RATIO = 0.18;
const TIMER_FLOOR_MS = 10;

function clamp(value, minimum, maximum) {
  return Math.min(Math.max(value, minimum), maximum);
}

function finiteNumber(value, fallback = null) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function wallClockNow() {
  return Date.now();
}

function monotonicNow() {
  return globalThis.performance?.now?.() ?? Date.now();
}

export default class HeartbeatPulseEngine {
  constructor({
    onPulse,
    onStop,
    onStateChange,
    setTimer = (callback, delay) => globalThis.setTimeout(callback, delay),
    clearTimer = (timer) => globalThis.clearTimeout(timer),
    now = wallClockNow,
    monotonic = monotonicNow,
  } = {}) {
    this.onPulse = onPulse;
    this.onStop = onStop;
    this.onStateChange = onStateChange;
    this.setTimer = setTimer;
    this.clearTimer = clearTimer;
    this.now = now;
    this.monotonic = monotonic;

    this.timer = null;
    this.healthTimer = null;
    this.running = false;
    this.health = "waiting";
    this.stopReason = null;
    this.signal = null;
    this.lastSignalAtMs = null;
    this.sourceMeasuredAtMs = null;
    this.sourceAgeAtReceiptMs = null;
    this.validUntilMs = 0;
    this.unstableAfterMs = 5000;
    this.lostAfterMs = 12000;
    this.targetIntervalMs = DEFAULT_INTERVAL_MS;
    this.smoothedIntervalMs = DEFAULT_INTERVAL_MS;
    this.nextPulseAtMonotonic = null;
    this.lastPulseAtMs = null;
    this.lastPatternAtMs = null;
    this.lastPulseError = null;
    this.transportUnstable = false;
    this.controlMode = "idle";
    this.pattern = null;

    this.diagnostics = {
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
    };
  }

  updateSignal(signal) {
    if (!signal?.active) {
      this.handleUnavailableSignal(signal);
      return;
    }

    const intervalMs = clamp(
      finiteNumber(signal?.pulse?.interval_ms, DEFAULT_INTERVAL_MS),
      MIN_INTERVAL_MS,
      MAX_INTERVAL_MS,
    );
    const validForMs = Math.max(
      finiteNumber(
        signal.valid_for_ms,
        finiteNumber(signal.expires_at_ms, 0) -
          finiteNumber(signal.server_time_ms, 0),
      ),
      0,
    );

    if (validForMs < MIN_VALIDITY_MS) {
      this.stop("signal_lost");
      return;
    }

    const receivedAtMs = this.now();
    const sourceAgeMs = Math.max(
      finiteNumber(signal.source_age_ms, 0),
      0,
    );

    this.signal = signal;
    this.lastSignalAtMs = receivedAtMs;
    this.sourceMeasuredAtMs = finiteNumber(signal.measured_at_ms, null);
    this.sourceAgeAtReceiptMs = sourceAgeMs;
    this.validUntilMs = receivedAtMs + validForMs;
    this.unstableAfterMs = Math.max(
      finiteNumber(signal.unstable_after_ms, 5000),
      1000,
    );
    this.lostAfterMs = Math.max(
      finiteNumber(signal.lost_after_ms, 12000),
      this.unstableAfterMs + 1000,
    );
    this.targetIntervalMs = intervalMs;
    this.smoothedIntervalMs = this.smoothInterval(intervalMs);
    this.stopReason = null;
    this.transportUnstable = false;
    this.diagnostics.signals_received += 1;

    if (!this.running) {
      this.running = true;
      this.nextPulseAtMonotonic = this.monotonic();
      this.schedulePulse();
    }

    this.refreshHealth();
    this.scheduleHealthCheck();
    this.publishState();
  }

  markTransportError() {
    this.diagnostics.transport_errors += 1;
    this.transportUnstable = true;
    if (this.running && this.now() < this.validUntilMs) {
      this.health = "unstable";
      this.publishState();
      this.scheduleHealthCheck();
      return;
    }

    if (this.running) {
      this.stop("signal_lost");
    } else {
      this.publishState();
    }
  }

  handleUnavailableSignal(signal) {
    const reason = signal?.reason || "signal_unavailable";
    const canUseGrace = reason === "signal_temporarily_unavailable";

    if (!canUseGrace || this.now() >= this.validUntilMs) {
      this.stop(reason === "no_fresh_heartbeat" ? "signal_lost" : reason);
      return;
    }

    this.transportUnstable = true;
    this.health = "unstable";
    this.stopReason = reason;
    this.publishState();
    this.scheduleHealthCheck();
  }

  stop(reason = "stopped", { notifyToy = true } = {}) {
    const wasRunning = this.running;
    this.running = false;
    this.health = reason === "signal_lost" ? "lost" : "waiting";
    this.stopReason = reason;
    this.transportUnstable = false;
    this.nextPulseAtMonotonic = null;
    this.controlMode = "idle";
    this.clearScheduledTimers();
    this.publishState();

    if (notifyToy && wasRunning && typeof this.onStop === "function") {
      Promise.resolve(this.onStop(reason)).catch(() => {});
    }
  }

  destroy() {
    this.stop("destroyed");
    this.onPulse = null;
    this.onStop = null;
    this.onStateChange = null;
  }

  snapshot() {
    return {
      running: this.running,
      health: this.health,
      stop_reason: this.stopReason,
      target_interval_ms: Math.round(this.targetIntervalMs),
      interval_ms: Math.round(this.smoothedIntervalMs),
      source_age_ms: this.estimatedSourceAgeMs(),
      valid_for_ms: Math.max(this.validUntilMs - this.now(), 0),
      last_signal_at_ms: this.lastSignalAtMs,
      last_pulse_at_ms: this.lastPulseAtMs,
      last_pattern_at_ms: this.lastPatternAtMs,
      last_pulse_error: this.lastPulseError,
      control_mode: this.controlMode,
      pattern_cycle_ms: this.pattern?.cycle_ms ?? null,
      pattern_step_ms: this.pattern?.interval_ms ?? null,
      pattern_on_ms: this.pattern?.on_ms ?? null,
      pattern_duty_percent: this.pattern?.duty_percent ?? null,
      pattern_run_seconds: this.pattern?.run_seconds ?? null,
      ...this.diagnostics,
    };
  }

  smoothInterval(nextIntervalMs) {
    if (!this.running || !Number.isFinite(this.smoothedIntervalMs)) {
      return nextIntervalMs;
    }

    const current = this.smoothedIntervalMs;
    const blended = current + (nextIntervalMs - current) * SMOOTHING_FACTOR;
    const maximumStep = Math.max(current * MAX_INTERVAL_STEP_RATIO, 25);
    return clamp(blended, current - maximumStep, current + maximumStep);
  }

  schedulePulse() {
    this.clearTimer(this.timer);
    this.timer = null;

    if (!this.running || this.nextPulseAtMonotonic === null) {
      return;
    }

    const delay = Math.max(
      this.nextPulseAtMonotonic - this.monotonic(),
      TIMER_FLOOR_MS,
    );
    this.timer = this.setTimer(() => this.handlePulseDue(), delay);
  }

  handlePulseDue() {
    this.timer = null;
    if (!this.running) {
      return;
    }

    if (this.now() >= this.validUntilMs) {
      this.stop("signal_lost");
      return;
    }

    const nowMonotonic = this.monotonic();
    const intervalMs = clamp(
      this.smoothedIntervalMs,
      MIN_INTERVAL_MS,
      MAX_INTERVAL_MS,
    );
    const latenessMs = Math.max(
      nowMonotonic - (this.nextPulseAtMonotonic ?? nowMonotonic),
      0,
    );
    const lateThresholdMs = Math.max(intervalMs * 0.65, 250);

    this.diagnostics.beats_due += 1;
    if (latenessMs > lateThresholdMs) {
      const missed = Math.max(Math.floor(latenessMs / intervalMs), 1);
      this.diagnostics.browser_beats_skipped_late += missed;
      this.nextPulseAtMonotonic = nowMonotonic + intervalMs;
    } else {
      this.nextPulseAtMonotonic =
        (this.nextPulseAtMonotonic ?? nowMonotonic) + intervalMs;
      if (this.nextPulseAtMonotonic <= nowMonotonic + TIMER_FLOOR_MS) {
        this.nextPulseAtMonotonic = nowMonotonic + intervalMs;
      }
    }

    const pulse = {
      ...this.signal?.pulse,
      interval_ms: Math.round(intervalMs),
    };

    try {
      const result = this.onPulse?.(pulse);
      Promise.resolve(result)
        .then((outcome) => this.handleControlOutcome(outcome))
        .catch((error) => this.recordCommandError(error));
    } catch (error) {
      this.recordCommandError(error);
    }

    this.refreshHealth();
    this.publishState();
    this.schedulePulse();
  }

  handleControlOutcome(outcome) {
    if (outcome === false || outcome?.status === "busy") {
      this.diagnostics.commands_skipped_busy += 1;
      this.publishState();
      return;
    }

    const mode = outcome?.mode || "fallback";
    const status = outcome?.status || "sent";
    const pattern = outcome?.pattern || null;
    const nowMs = this.now();

    this.controlMode = mode;
    this.lastPulseAtMs = nowMs;
    this.lastPulseError = null;

    if (mode === "pattern") {
      this.diagnostics.pattern_cycles_estimated += 1;
      if (status === "updated") {
        this.diagnostics.pattern_updates += 1;
        this.lastPatternAtMs = nowMs;
      } else {
        this.diagnostics.pattern_reuses += 1;
      }
      if (pattern) {
        this.pattern = { ...pattern };
      }
    } else {
      this.diagnostics.fallback_pulses_sent += 1;
    }

    this.publishState();
  }

  recordCommandError(error) {
    this.diagnostics.command_errors += 1;
    this.lastPulseError = error?.message || String(error || "command_error");
    this.publishState();
  }

  scheduleHealthCheck() {
    this.clearTimer(this.healthTimer);
    this.healthTimer = null;
    if (!this.running) {
      return;
    }

    const remainingMs = Math.max(this.validUntilMs - this.now(), 0);
    const delay = Math.max(Math.min(remainingMs, 500), TIMER_FLOOR_MS);
    this.healthTimer = this.setTimer(() => {
      this.healthTimer = null;
      if (!this.running) {
        return;
      }
      if (this.now() >= this.validUntilMs) {
        this.stop("signal_lost");
        return;
      }
      this.refreshHealth();
      this.publishState();
      this.scheduleHealthCheck();
    }, delay);
  }

  refreshHealth() {
    if (!this.running) {
      return;
    }

    const sourceAgeMs = this.estimatedSourceAgeMs();
    this.health =
      this.transportUnstable || sourceAgeMs >= this.unstableAfterMs
        ? "unstable"
        : "live";
  }

  estimatedSourceAgeMs() {
    if (this.sourceAgeAtReceiptMs === null || this.lastSignalAtMs === null) {
      return null;
    }

    return Math.max(
      this.sourceAgeAtReceiptMs + (this.now() - this.lastSignalAtMs),
      0,
    );
  }

  clearScheduledTimers() {
    this.clearTimer(this.timer);
    this.timer = null;
    this.clearTimer(this.healthTimer);
    this.healthTimer = null;
  }

  publishState() {
    this.onStateChange?.(this.snapshot());
  }
}
