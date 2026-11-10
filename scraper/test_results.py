"""Сбор и прошлые сезоны: протокол из архива прошлых сезонов не берётся в архив сбора (results._in_past)."""
import os
import tempfile
import unittest
from unittest import mock

from scraper import archive as ar
from scraper import results as rs

PAST_PDF = "https://fsrussia.ru/results/2425/1etap/x_JudgesDetailsperSkater.pdf"
OTHER_PDF = "https://fsrussia.ru/results/2425/2etap/y_JudgesDetailsperSkater.pdf"


class InPastTest(unittest.TestCase):
    def setUp(self):
        self.addCleanup(setattr, rs, "_past", None)
        rs._past = None
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.path = os.path.join(tmp.name, "past.json")
        arc = ar.empty()
        ar.ingest(arc, [{"name": "Ilia MALININ", "nation": "USA", "components": [],
                         "elements": [{"code": "4A", "info": "", "base": 12.5, "goe": 0.5, "judges": [1, 1, 1],
                                       "score": 13.0}]}],
                  {"u": PAST_PDF, "ev": "Турнир", "d": "2024-11-01", "kind": "men", "level": "senior", "seg": "ПП",
                   "src": "ISU"})
        ar.save(arc, self.path)
        patch = mock.patch.object(rs, "PAST", self.path)
        patch.start()
        self.addCleanup(patch.stop)

    def test_reads_file_once(self):
        real_load = ar.load
        with mock.patch.object(ar, "load", side_effect=real_load) as load:
            self.assertTrue(rs._in_past(PAST_PDF))
            self.assertFalse(rs._in_past(OTHER_PDF))
            self.assertTrue(rs._in_past(PAST_PDF))
        self.assertEqual(load.call_count, 1)
        self.assertEqual(load.call_args[0][0], self.path)


if __name__ == "__main__":
    unittest.main()
