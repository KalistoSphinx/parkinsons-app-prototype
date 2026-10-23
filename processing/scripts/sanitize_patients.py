import json
from pathlib import Path
from processing.app.feature_store import feature_store
from processing.app.main import alert_store
from processing.app.anomaly import evaluate as evaluate_anomaly, detect_context
from processing.app.feature_store import PARADIGMA_GAIT_THRESHOLD, symptom_labels

p = Path('processing/data/feature_vectors/6dfdc343caea40c379cd743e5854102dd6bea0321249d4174524736af0a42a1d')
patient_id = 'paradigma-public-ppp-demo'

if p.exists():
    for name in ('_baseline.json', '_reference_baseline.json', '_anomaly_model.joblib', '_alert_state.json', '_alerts.jsonl'):
        f = p / name
        if f.exists():
            f.unlink()

    files = sorted([f for f in p.glob('*.json') if not f.name.startswith('_')])
    for f in files[7:]:
        d = json.loads(f.read_text(encoding='utf-8'))
        d['monitoring_mode'] = 'anomaly'
        d['baseline_status'] = 'excluded'
        f.write_text(json.dumps(d, indent=2), encoding='utf-8')

    for f in files[:7]:
        d = json.loads(f.read_text(encoding='utf-8'))
        d['monitoring_mode'] = 'baseline'
        d['baseline_status'] = 'included'
        f.write_text(json.dumps(d, indent=2), encoding='utf-8')

    stats = feature_store._load_or_rebuild_stats(p)
    print('Rebuilt stats session count:', stats['quality_session_count'])
    print('Rebuilt stats max tremor_prob:', stats['features']['tremor_probability']['max'])

    finalized = feature_store.finalize_baseline(patient_id)
    print('Finalized reference session count:', finalized['reference_sessions'])
    ref = finalized['baseline']
    print('Baseline max tremor prob:', ref['tremor_probability']['max'])

    for f in files[7:]:
        d = json.loads(f.read_text(encoding='utf-8'))
        features = d.get('features', {})
        labels = symptom_labels(features, ref)
        anom = evaluate_anomaly(features, ref, labels, detect_context(features, PARADIGMA_GAIT_THRESHOLD), None)
        recent = feature_store.recent_sessions(patient_id, limit=3)
        alerts = alert_store.evaluate(
            patient_id=patient_id,
            session_id=d['session_id'],
            timestamp_ms=d['timestamp_ms'],
            created_at=d['timestamp'],
            anomaly=anom,
            recent_sessions=recent,
        )
        d['symptom_labels'] = labels
        d['anomaly'] = anom
        d['alert_ids'] = [a['alert_id'] for a in alerts]
        f.write_text(json.dumps(d, indent=2), encoding='utf-8')
        sid = d['session_id']
        sev = anom['severity']
        print(f'{sid}: labels={labels}, anomaly_sev={sev}, alerts_count={len(alerts)}')
