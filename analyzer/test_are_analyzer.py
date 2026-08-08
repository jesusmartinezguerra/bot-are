import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).parent))
from are_analyzer import Bar, Config, parse_timestamp, score_bars


class AnalyzerTests(unittest.TestCase):
    def test_timestamp_parser_is_monotonic_without_timezone_conversion(self):
        cache = {}
        first, first_minute = parse_timestamp("20260101 000000000", cache)
        second, second_minute = parse_timestamp("20260101 000100000", cache)
        self.assertEqual(second - first, 60_000)
        self.assertEqual(second_minute - first_minute, 1)

    def test_scores_do_not_change_when_future_bars_are_appended(self):
        bars = []
        for i in range(160):
            price = 100 + (i % 7) * 0.1 + i * 0.01
            bars.append(Bar(738000000 + i, price, price + .05, price - .05, price, .01, 10))
        base = score_bars("TEST", bars, Config())
        future = bars + [Bar(738000160 + i, 103, 103.1, 102.9, 103, .01, 10) for i in range(5)]
        extended = score_bars("TEST", future, Config())
        self.assertEqual(base, extended[:len(base)])


if __name__ == "__main__":
    unittest.main()
