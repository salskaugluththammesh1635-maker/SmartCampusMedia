"""Regression tests for caption preview validation."""
from __future__ import annotations

import contextlib
import io
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from PIL import Image

from scripts import verify_caption_preview as verifier


class CaptionPreviewValidationTests(unittest.TestCase):
    @staticmethod
    def make_ticker(path: Path, scroll: int) -> None:
        image = Image.new("RGB", (640, 480), (0, 0, 0))
        pixels = image.load()
        glyph_columns = {17, 88, 301}
        glyph_rows = {0, 3, 15}
        for y in range(verifier.TICKER_Y0, verifier.TICKER_Y0 + 16):
            for x in range(640):
                if ((x + scroll) % verifier.TICKER_PERIOD in glyph_columns
                        and y - verifier.TICKER_Y0 in glyph_rows):
                    pixels[x, y] = verifier.GLYPH
        image.save(path)

    def test_missing_scroll_image_fails_even_when_ocr_passes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = root / "static.png"
            missing = root / "scroll.png"
            output = io.StringIO()
            argv = ["verify_caption_preview", "--png", str(first), "--png2", str(missing)]
            with (
                patch.object(verifier, "ROOT", root),
                patch.object(verifier, "FONT_V", root / "font.v"),
                patch.object(verifier, "parse_font", return_value={}),
                patch.object(verifier, "ocr_bands", return_value=0),
                patch.object(sys, "argv", argv),
                contextlib.redirect_stdout(output),
            ):
                result = verifier.main()

        self.assertEqual(result, 1)
        self.assertIn("CAPTION PREVIEW FAILED", output.getvalue())
        self.assertNotIn("CAPTION PREVIEW OK", output.getvalue())

    def test_correct_ticker_translation_passes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first, shifted = root / "first.png", root / "shifted.png"
            self.make_ticker(first, scroll=0)
            self.make_ticker(shifted, scroll=8)

            with contextlib.redirect_stdout(io.StringIO()):
                mismatch = verifier.ticker_shift_check(first, 0, shifted, 8)
            self.assertEqual(mismatch, 0)

    def test_wrong_ticker_translation_is_detected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first, shifted = root / "first.png", root / "shifted.png"
            self.make_ticker(first, scroll=0)
            self.make_ticker(shifted, scroll=9)

            with contextlib.redirect_stdout(io.StringIO()):
                mismatch = verifier.ticker_shift_check(first, 0, shifted, 8)
            self.assertGreater(mismatch, 0)


if __name__ == "__main__":
    unittest.main()
