"""Personal-baseline anomaly scoring for compact movement feature vectors.

The scorer is deliberately two-stage:

1. Direction-aware robust z-scores (median/MAD) work from the first few
   baseline intervals and explain *which* signal changed.
2. An Isolation Forest adds a multivariate second opinion once enough
   baseline intervals exist. It never creates an alert on its own; it only
   corroborates or escalates an explainable univariate deviation.
"""

from __future__ import annotations

import math
from pathlib import Path
from typing import Any

import numpy as np

HIGH_IS_BAD = ("tremor_probability", "tremor_power", "tremor_time")
LOW_IS_BAD = ("arm_swing_rom", "arm_swing_peak_velocity", "gyro_rms_rad_s")

TREMOR_FEATURES = set(HIGH_IS_BAD)
GAIT_FEATURES = {"arm_swing_rom", "arm_swing_peak_velocity"}
MOVEMENT_FEATURES = {"gyro_rms_rad_s"}

# Always-available features used by the multivariate model. Arm-swing values
# are excluded because they are null when the patient is not walking; those
# are scored by the univariate robust-z stage instead.
CORE_FEATURES = (
    "tremor_probability",
    "gait_probability",
    "accel_rms_m_s2",
    "gyro_rms_rad_s",
)

NOISE_FLOORS = {
    "tremor_probability": 0.029570239921802,
    "tremor_power": 1.0,
    "tremor_time": 0.05,
    "arm_swing_rom": 2.0,
    "arm_swing_peak_velocity": 10.0,
    "gyro_rms_rad_s": 0.05,
}

SEVERITY_RANK = {"normal": 0, "watch": 1, "warning": 2, "critical": 3}
LABEL_SEVERITY = {
    "normal": "normal",
    "mild": "watch",
    "moderate": "warning",
    "severe": "critical",
    "critical": "critical",
}

def _max_severity(left: str | None, right: str | None) -> str:
    if left is None:
        return right or "normal"
    if right is None:
        return left
    return left if SEVERITY_RANK.get(left, 0) >= SEVERITY_RANK.get(right, 0) else right


def _z_severity(z: float) -> str:
    if z >= 3.5:
        return "critical"
    if z >= 2.5:
        return "warning"
    if z >= 2.0:
        return "watch"
    return "normal"


def detect_context(features: dict[str, Any], gait_threshold: float) -> str:
    """Use the existing ParaDigMa outputs to separate rest from walking.

    Mixing rest and walking intervals in one baseline makes both tremor and
    movement-vigor comparisons much noisier. This gate keeps each alert tied
    to the activity context in which it is meaningful.
    """
    if features.get("arm_swing_rom") is not None:
        return "walking"
    gait = features.get("gait_probability")
    if gait is not None and float(gait) >= gait_threshold:
        return "walking"
    return "rest"


def _driver_symptom(feature: str) -> str | None:
    if feature in TREMOR_FEATURES:
        return "tremor"
    if feature in GAIT_FEATURES:
        return "gait"
    if feature in MOVEMENT_FEATURES:
        return "bradykinesia_proxy"
    return None


def within_observed_range(
    feature: str,
    value: float,
    stats: dict[str, Any],
) -> bool:
    """Return True when a value has already been observed in the baseline.

    Tremor features are zero-inflated: most intervals are near zero while a
    few contain real tremor. That makes the MAD extremely small, so a value
    that is still inside the patient's historical range can look like a large
    robust-z outlier. The observed min/max gate prevents re-labelling known
    patient variability as a new change.
    """
    if int(stats.get("count", 0)) < 5:
        return False
    if feature in LOW_IS_BAD:
        lower = stats.get("min")
        return lower is not None and value >= float(lower)
    upper = stats.get("max")
    return upper is not None and value <= float(upper)


def robust_drivers(
    features: dict[str, Any],
    baseline: dict[str, dict[str, Any]],
    context: str,
) -> list[dict[str, Any]]:
    """Return direction-aware robust deviations, largest first."""
    drivers: list[dict[str, Any]] = []
    for name in (*HIGH_IS_BAD, *LOW_IS_BAD):
        if name in TREMOR_FEATURES and context != "rest":
            continue
        if name in (GAIT_FEATURES | MOVEMENT_FEATURES) and context != "walking":
            continue
        stats = baseline.get(name)
        value = features.get(name)
        if value is None or stats is None or int(stats.get("count", 0)) < 5:
            continue
        try:
            numeric = float(value)
        except (TypeError, ValueError):
            continue
        if not math.isfinite(numeric):
            continue
        if within_observed_range(name, numeric, stats):
            continue

        median = float(stats.get("median", stats.get("mean", 0.0)))
        spread = 1.4826 * float(stats.get("mad", 0.0) or 0.0)
        if spread <= 0:
            spread = float(stats.get("std", 0.0) or 0.0)
        spread = max(spread, NOISE_FLOORS.get(name, 1e-4), 1e-6)
        direction = 1.0 if name in HIGH_IS_BAD else -1.0
        z = direction * (numeric - median) / spread
        if z <= 0:
            continue
        drivers.append(
            {
                "feature": name,
                "z": round(float(z), 2),
                "value": round(numeric, 6),
                "baseline_median": round(median, 6),
                "direction": "high" if direction > 0 else "low",
                "symptom": _driver_symptom(name),
            }
        )
    drivers.sort(key=lambda item: item["z"], reverse=True)
    return drivers


def fit_isolation_model(rows: list[dict[str, Any]]) -> dict[str, Any] | None:
    """Fit a per-patient Isolation Forest when there is enough baseline data."""
    if len(rows) < 20:
        return None
    try:
        from sklearn.ensemble import IsolationForest
    except Exception:
        return None

    matrix = np.asarray(
        [[row.get(name) for name in CORE_FEATURES] for row in rows],
        dtype=float,
    )
    if matrix.ndim != 2 or matrix.shape[0] < 20:
        return None

    medians = np.nanmedian(matrix, axis=0)
    medians = np.where(np.isfinite(medians), medians, 0.0)
    filled = np.where(np.isfinite(matrix), matrix, medians)

    model = IsolationForest(
        n_estimators=200,
        contamination=0.05,
        random_state=42,
    )
    model.fit(filled)
    train_scores = -model.score_samples(filled)
    low, high = np.percentile(train_scores, [50, 99])
    return {
        "model": model,
        "features": list(CORE_FEATURES),
        "medians": [float(value) for value in medians],
        "low": float(low),
        "high": float(high),
        "count": len(rows),
    }


def save_model(bundle: dict[str, Any], path: Path) -> None:
    import joblib

    path.parent.mkdir(parents=True, exist_ok=True)
    joblib.dump(bundle, path)


def load_model(path: Path) -> dict[str, Any] | None:
    if not path.exists():
        return None
    try:
        import joblib

        return joblib.load(path)
    except Exception:
        return None


def score_isolation(
    bundle: dict[str, Any] | None,
    features: dict[str, Any],
) -> float | None:
    if not bundle:
        return None
    try:
        values = [features.get(name) for name in bundle["features"]]
        vector = np.asarray([values], dtype=float)
        medians = np.asarray(bundle["medians"], dtype=float)
        vector = np.where(np.isfinite(vector), vector, medians)
        raw = -float(bundle["model"].score_samples(vector)[0])
        low = float(bundle["low"])
        high = float(bundle["high"])
        return float(np.clip((raw - low) / max(high - low, 1e-9), 0.0, 1.0))
    except Exception:
        return None


def evaluate(
    features: dict[str, Any],
    baseline: dict[str, dict[str, Any]],
    labels: dict[str, str],
    context: str,
    isolation_bundle: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Combine robust deviations, absolute labels, and the multivariate score.

    The Isolation Forest is intentionally a corroborator, not a standalone
    alert source. This keeps every alert explainable through its ``drivers``
    list, which is important for a clinical prototype.
    """
    drivers = robust_drivers(features, baseline, context)
    stat_z = float(drivers[0]["z"]) if drivers else 0.0
    if_score = score_isolation(isolation_bundle, features)

    severity = _z_severity(stat_z)
    if severity == "watch" and if_score is not None and if_score >= 0.95:
        severity = "warning"

    symptoms: dict[str, str] = {}
    for driver in drivers[:3]:
        symptom = driver.get("symptom")
        if not symptom:
            continue
        symptoms[symptom] = _max_severity(
            symptoms.get(symptom),
            _z_severity(float(driver["z"])),
        )

    # Absolute ParaDigMa-derived labels still matter. A personal baseline must
    # not normalize away a clearly high absolute tremor measurement.
    for symptom, label in labels.items():
        mapped = LABEL_SEVERITY.get(label, "normal")
        if SEVERITY_RANK[mapped] < 2:
            continue
        if symptom in {"tremor", "fall"} or context == "walking":
            symptoms[symptom] = _max_severity(symptoms.get(symptom), mapped)

    # Acute sudden fall detection immediately escalates to critical with an explainable driver.
    if features.get("fall_detected") == 1.0:
        impact_g = float(features.get("fall_impact_g") or 2.5)
        severity = "critical"
        symptoms["fall"] = "critical"
        fall_driver = {
            "feature": "fall_impact_g",
            "z": round(max(4.0, (impact_g - 1.0) / 0.5), 2),
            "value": round(impact_g, 2),
            "baseline_median": 1.0,
            "direction": "high",
            "symptom": "fall",
        }
        drivers.insert(0, fall_driver)

    if not symptoms and severity in {"warning", "critical"}:
        # A multivariate-only pattern with no explainable driver is retained
        # as a watch item instead of producing an unexplainable alert.
        severity = "watch"

    combined = 1.0 if features.get("fall_detected") == 1.0 else max(min(stat_z / 4.0, 1.0), if_score or 0.0)
    return {
        "score": round(float(combined), 3),
        "severity": severity,
        "model": "robust_z+isolation_forest" if isolation_bundle else "robust_z",
        "stat_z": round(stat_z, 2),
        "if_score": round(float(if_score), 3) if if_score is not None else None,
        "context": context,
        "drivers": drivers[:3],
        "symptoms": symptoms,
    }

