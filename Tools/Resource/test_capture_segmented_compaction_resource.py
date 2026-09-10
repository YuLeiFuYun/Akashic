#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import pathlib
import sys
import unittest

RESOURCE = pathlib.Path(__file__).resolve().parent
if str(RESOURCE) not in sys.path:
    sys.path.insert(0, str(RESOURCE))

spec = importlib.util.spec_from_file_location(
    "capture_segmented_compaction_resource",
    RESOURCE / "capture_segmented_compaction_resource.py",
)
if spec is None or spec.loader is None:
    raise RuntimeError("unable to load compaction capture module")
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)


class CrossProfileComparisonTests(unittest.TestCase):
    def sample(
        self,
        profile: str,
        mode: str,
        authority: str,
        *,
        frozen: str = "frozen",
    ) -> dict[str, object]:
        return {
            "caseID": "case",
            "profile": profile,
            "repetition": 0,
            "mode": mode,
            "foregroundP95Nanoseconds": 100,
            "child": {
                "actorLogicalAuthorityCommitment": authority,
                "frozenIdentityCommitment": frozen,
                "finalBaseBytes": 100,
            },
        }

    def pair(self, profile: str) -> dict[str, object]:
        return {
            "caseID": "case",
            "profile": profile,
            "repetition": 0,
            "filesystemWriteDeltaBytes": 10,
            "instructionDelta": 10,
        }

    def test_expected_mode_difference_still_preserves_cross_profile_authority(self) -> None:
        samples = [
            self.sample("v1-json", "baseline", "baseline-authority"),
            self.sample("v1-json", "compaction", "compaction-authority"),
            self.sample("v2-binary", "baseline", "baseline-authority"),
            self.sample("v2-binary", "compaction", "compaction-authority"),
        ]
        result = module.cross_profile_comparisons(
            samples,
            [self.pair("v1-json"), self.pair("v2-binary")],
        )
        self.assertEqual(len(result), 1)
        self.assertTrue(result[0]["logicalAuthorityCommitmentExact"])

    def test_same_mode_profile_mismatch_fails_closed(self) -> None:
        samples = [
            self.sample("v1-json", "baseline", "baseline-authority"),
            self.sample("v1-json", "compaction", "compaction-authority"),
            self.sample("v2-binary", "baseline", "wrong-authority"),
            self.sample("v2-binary", "compaction", "compaction-authority"),
        ]
        result = module.cross_profile_comparisons(
            samples,
            [self.pair("v1-json"), self.pair("v2-binary")],
        )
        self.assertEqual(len(result), 1)
        self.assertFalse(result[0]["logicalAuthorityCommitmentExact"])


if __name__ == "__main__":
    unittest.main()
