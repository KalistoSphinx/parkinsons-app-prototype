import tempfile
import unittest
from pathlib import Path

from processing.app.feature_store import FeatureStore
from processing.app.pairing import PairingStore


class PairingStoreTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.store = PairingStore(Path(self.temp_dir.name) / "test_codes.json")
        self.feature_store = FeatureStore(Path(self.temp_dir.name) / "patients")

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_generate_and_claim_code(self):
        gen = self.store.generate("patient-123", "Alice Smith", ttl_seconds=60)
        code = gen["code"]
        self.assertEqual(len(code), 6)
        self.assertTrue(code.isdigit())

        active = self.store.active_for_patient("patient-123")
        self.assertIsNotNone(active)
        self.assertEqual(active["code"], code)

        # Claim with formatting (e.g. "123-456")
        formatted = f"{code[:3]}-{code[3:]}"
        claim_res = self.store.claim(formatted)
        self.assertIsNotNone(claim_res)
        self.assertEqual(claim_res["patient_id"], "patient-123")
        self.assertEqual(claim_res["patient_name"], "Alice Smith")

    def test_invalid_or_expired_code(self):
        res = self.store.claim("000000")
        self.assertIsNone(res)

        # Expired code (ttl = -1s)
        gen = self.store.generate("patient-expired", ttl_seconds=-1)
        res_expired = self.store.claim(gen["code"])
        self.assertIsNone(res_expired)

    def test_caretaker_profile_lifecycle(self):
        patient_id = "patient-carer-test"
        self.assertIsNone(self.feature_store.get_caretaker(patient_id))

        # Save caretaker
        self.feature_store.save_caretaker(patient_id, {
            "caretaker_name": "Sarah Connor",
            "paired_at_ms": 1700000000000,
            "active": True
        })
        caretaker = self.feature_store.get_caretaker(patient_id)
        self.assertIsNotNone(caretaker)
        self.assertEqual(caretaker["caretaker_name"], "Sarah Connor")

        # Update caretaker name
        caretaker["caretaker_name"] = "Dr. John Watson"
        self.feature_store.save_caretaker(patient_id, caretaker)
        updated = self.feature_store.get_caretaker(patient_id)
        self.assertEqual(updated["caretaker_name"], "Dr. John Watson")

        # Remove caretaker
        removed = self.feature_store.remove_caretaker(patient_id)
        self.assertTrue(removed)
        self.assertIsNone(self.feature_store.get_caretaker(patient_id))


if __name__ == "__main__":
    unittest.main()
