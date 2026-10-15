"""Сетевой слой на моках: python3 -m unittest scraper.test_net

Проверяем kind и status у FetchError: их читает сборщик, чтобы отличить «табло ответило
404» от «табло молчит» и не понижать окончательный протокол из-за сети. Сети не нужно."""
import socket
import unittest
import urllib.error
from unittest import mock

from . import net


def _http(code):
    return urllib.error.HTTPError("https://x.test/a", code, "boom", {}, None)


class Fetch(unittest.TestCase):
    def setUp(self):
        # без пауз между повторами и троттлинга
        for patcher in (mock.patch.object(net.time, "sleep"),
                        mock.patch.object(net, "_throttle")):
            patcher.start()
            self.addCleanup(patcher.stop)

    def _fetch_raising(self, exc, tries=3):
        with mock.patch.object(net.urllib.request, "urlopen", side_effect=exc) as op:
            with self.assertRaises(net.FetchError) as ctx:
                net.fetch("https://x.test/a", tries=tries)
        return ctx.exception, op.call_count

    def test_404_is_http_and_not_retried(self):
        err, calls = self._fetch_raising(_http(404))
        self.assertEqual((err.kind, err.status), ("http", 404))
        self.assertEqual(calls, 1)

    def test_410_and_403_are_not_retried(self):
        for code in (403, 410):
            err, calls = self._fetch_raising(_http(code))
            self.assertEqual((err.kind, err.status, calls), ("http", code, 1))

    def test_500_is_http_and_retried(self):
        err, calls = self._fetch_raising(_http(503))
        self.assertEqual((err.kind, err.status), ("http", 503))
        self.assertEqual(calls, 3)

    def test_socket_timeout_is_timeout(self):
        err, _ = self._fetch_raising(socket.timeout("timed out"), tries=1)
        self.assertEqual((err.kind, err.status), ("timeout", None))

    def test_urlerror_with_timeout_reason_is_timeout(self):
        err, _ = self._fetch_raising(urllib.error.URLError(socket.timeout("timed out")), tries=1)
        self.assertEqual(err.kind, "timeout")

    def test_connection_refused_is_net(self):
        err, _ = self._fetch_raising(urllib.error.URLError("connection refused"), tries=1)
        self.assertEqual((err.kind, err.status), ("net", None))

    def test_message_text_is_unchanged(self):
        err, _ = self._fetch_raising(_http(404), tries=1)
        self.assertIn("https://x.test/a", str(err))
        self.assertIsInstance(err, net.FetchError)

    def test_default_error_kind_is_net(self):
        e = net.FetchError("сообщение")
        self.assertEqual((e.kind, e.status, str(e)), ("net", None, "сообщение"))


class Pdf(unittest.TestCase):
    def test_not_pdf_is_format(self):
        with mock.patch.object(net, "fetch", return_value=b"<html>") as f:
            with self.assertRaises(net.FetchError) as ctx:
                net.pdf_text("https://x.test/a.pdf")
        self.assertEqual(ctx.exception.kind, "format")
        self.assertIsNone(ctx.exception.status)
        f.assert_called_once()


class Decode(unittest.TestCase):
    def test_utf8_then_cp1251(self):
        self.assertEqual(net._decode("Протокол".encode("utf-8")), "Протокол")
        self.assertEqual(net._decode("Протокол".encode("cp1251")), "Протокол")


if __name__ == "__main__":
    unittest.main()
