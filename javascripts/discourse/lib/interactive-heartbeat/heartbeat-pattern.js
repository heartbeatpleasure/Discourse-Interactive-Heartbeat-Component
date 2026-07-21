const MIN_HEARTBEAT_INTERVAL_MS = 273;
const MAX_HEARTBEAT_INTERVAL_MS = 2000;
const TARGET_PATTERN_STEP_MS = 130;
const MIN_PATTERN_STEP_MS = 101;
const MAX_PATTERN_STEPS = 18;
const MIN_FEELABLE_ON_MS = 220;
const MAX_ON_MS = 500;
const DEFAULT_RUN_SECONDS = 10;
const DEFAULT_REFRESH_LEAD_MS = 3000;
const MIN_INTERVAL_CHANGE_MS = 40;
const MIN_INTERVAL_CHANGE_RATIO = 0.05;
const MIN_DYNAMIC_UPDATE_GAP_MS = 2500;
const MIN_STRENGTH_CHANGE = 2;

function clamp(value, minimum, maximum) {
  return Math.min(Math.max(value, minimum), maximum);
}

function finiteNumber(value, fallback) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

export function buildHeartbeatPattern({
  intervalMs,
  strength,
  maxIntensity = 20,
  requestedPulseDurationMs = 180,
  runSeconds = DEFAULT_RUN_SECONDS,
} = {}) {
  const safeIntervalMs = clamp(
    finiteNumber(intervalMs, 750),
    MIN_HEARTBEAT_INTERVAL_MS,
    MAX_HEARTBEAT_INTERVAL_MS,
  );
  const safeStrength = clamp(
    Math.round(finiteNumber(strength, 12)),
    1,
    clamp(Math.round(finiteNumber(maxIntensity, 20)), 1, 20),
  );

  const totalSteps = clamp(
    Math.round(safeIntervalMs / TARGET_PATTERN_STEP_MS),
    2,
    MAX_PATTERN_STEPS,
  );
  const stepMs = Math.max(
    Math.round(safeIntervalMs / totalSteps),
    MIN_PATTERN_STEP_MS,
  );
  const cycleMs = stepMs * totalSteps;

  const requestedOnMs = clamp(
    finiteNumber(requestedPulseDurationMs, 180),
    100,
    MAX_ON_MS,
  );
  const desiredOnMs = clamp(
    Math.max(requestedOnMs, cycleMs * 0.4, MIN_FEELABLE_ON_MS),
    MIN_PATTERN_STEP_MS,
    Math.min(MAX_ON_MS, cycleMs - stepMs),
  );
  const onSteps = clamp(
    Math.ceil(desiredOnMs / stepMs),
    1,
    totalSteps - 1,
  );
  const onMs = onSteps * stepMs;
  const offMs = cycleMs - onMs;
  const values = Array.from({ length: totalSteps }, (_, index) =>
    index < onSteps ? safeStrength : 0,
  );
  const safeRunSeconds = Math.max(
    Math.round(finiteNumber(runSeconds, DEFAULT_RUN_SECONDS)),
    2,
  );

  return {
    strength: values.join(";"),
    values,
    vibrate: true,
    interval_ms: stepMs,
    cycle_ms: cycleMs,
    requested_interval_ms: Math.round(safeIntervalMs),
    requested_on_ms: Math.round(requestedOnMs),
    on_ms: onMs,
    off_ms: offMs,
    duty_percent: Math.round((onMs / cycleMs) * 100),
    total_steps: totalSteps,
    on_steps: onSteps,
    strength_level: safeStrength,
    run_seconds: safeRunSeconds,
    refresh_after_ms: Math.max(
      safeRunSeconds * 1000 - DEFAULT_REFRESH_LEAD_MS,
      2000,
    ),
  };
}

export function shouldReplaceHeartbeatPattern(
  current,
  next,
  { nowMs = Date.now(), refreshAtMs = 0 } = {},
) {
  if (!current || !next) {
    return true;
  }

  if (nowMs >= refreshAtMs) {
    return true;
  }

  if (
    current.toy_id !== next.toy_id ||
    current.requested_on_ms !== next.requested_on_ms
  ) {
    return true;
  }

  const lastUpdatedAtMs = Number(current.updated_at_ms || 0);
  const dynamicUpdateAllowed =
    !lastUpdatedAtMs || nowMs - lastUpdatedAtMs >= MIN_DYNAMIC_UPDATE_GAP_MS;
  const strengthDifference = Math.abs(
    Number(current.strength_level) - Number(next.strength_level),
  );
  if (dynamicUpdateAllowed && strengthDifference >= MIN_STRENGTH_CHANGE) {
    return true;
  }

  const intervalDifference = Math.abs(
    Number(current.cycle_ms) - Number(next.cycle_ms),
  );
  const meaningfulIntervalDifference = Math.max(
    MIN_INTERVAL_CHANGE_MS,
    Number(current.cycle_ms) * MIN_INTERVAL_CHANGE_RATIO,
  );

  return dynamicUpdateAllowed && intervalDifference >= meaningfulIntervalDifference;
}
