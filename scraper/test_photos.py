"""Фото спортсменов: найденное не пропадает, имена в разных написаниях сходятся."""
import json
import os
import tempfile
import unittest
from unittest import mock

from scraper import names as nm
from scraper import net, photos as ph


def _names(*ru):
    n = nm.Names()
    for x in ru:
        n.add(x)
    return n


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.site = os.path.join(self.tmp.name, "site")
        os.makedirs(os.path.join(self.site, "photos"))
        self.book = os.path.join(self.tmp.name, "people.json")
        self.skip = os.path.join(self.tmp.name, "photo_skip.json")

    def thumb(self, name="old.jpg"):
        rel = f"photos/{name}"
        with open(os.path.join(self.site, rel), "wb") as f:
            f.write(b"x" * 2000)
        return rel

    def run_collect(self, want, raw, prev=None, names=None, is_image=lambda u: True, make=None, wiki_ok=True):
        names = names or _names(*[w for w in want if nm.is_cyr(w)])
        with mock.patch.object(ph, "make2", make or (lambda s, u: (None, "fail"))), \
                mock.patch.object(ph, "_polite", lambda u: None):
            return ph.collect(self.site, want, raw, prev or {}, names, self.book, self.skip,
                              log=lambda *a: None, is_image=is_image, wiki_ok=wiki_ok)

    def seed(self, name_ru, rel, prio, url="https://x/old"):
        names = _names(name_ru)
        ph.save_book(self.book, {nm.key(name_ru): {"f": rel, "u": url, "p": prio, "c": ph.CUT}})
        return names


class KeepTest(Base):
    def test_network_down_keeps_photo(self):
        rel = self.thumb()
        names = self.seed("Ксения Синицына", rel, 2)
        out = self.run_collect(["Ксения Синицына"], [("Kseniia SINITSYNA", "https://x/new", 0)],
                               names=names, is_image=lambda u: None)
        self.assertEqual(out["Ксения Синицына"], rel)
        self.assertTrue(os.path.exists(os.path.join(self.site, rel)))

    def test_source_vanished_keeps_photo_and_file(self):
        rel = self.thumb()
        names = self.seed("Ксения Синицына", rel, 2)
        out = self.run_collect(["Ксения Синицына"], [], names=names)
        self.assertEqual(out["Ксения Синицына"], rel)
        self.assertTrue(os.path.exists(os.path.join(self.site, rel)))  # prune не трогает

    def test_failed_cut_keeps_old(self):
        rel = self.thumb()
        names = self.seed("Ксения Синицына", rel, 2)
        out = self.run_collect(["Ксения Синицына"], [("Kseniia SINITSYNA", "https://x/better", 0)], names=names)
        self.assertEqual(out["Ксения Синицына"], rel)

    def test_more_trusted_source_replaces(self):
        rel = self.thumb()
        names = self.seed("Ксения Синицына", rel, 2)
        new = self.thumb("new.jpg")
        out = self.run_collect(["Ксения Синицына"], [("Kseniia SINITSYNA", "https://x/better", 0)],
                               names=names, make=lambda s, u: (new, "ok"))
        self.assertEqual(out["Ксения Синицына"], new)
        self.assertEqual(ph.load_book(self.book)[nm.key("Ксения Синицына")]["p"], 0)

    def test_less_trusted_source_does_not_replace_and_is_not_fetched(self):
        rel = self.thumb()
        names = self.seed("Ксения Синицына", rel, 0)
        calls = []
        out = self.run_collect(["Ксения Синицына"], [("Kseniia SINITSYNA", "https://x/wiki", 3)], names=names,
                               is_image=lambda u: calls.append(u) or True,
                               make=lambda s, u: calls.append(u) or ("photos/zzz.jpg", "ok"))
        self.assertEqual(out["Ксения Синицына"], rel)
        self.assertEqual(calls, [])

    def test_previous_events_json_photo_is_adopted_only_while_wikidata_is_silent(self):
        # источник неизвестен: пока Викиданные не ответили, не трогаем
        rel = self.thumb()
        out = self.run_collect(["Ксения Синицына"], [], prev={"Ксения Синицына": rel}, wiki_ok=False)
        self.assertEqual(out["Ксения Синицына"], rel)
        self.assertIn(nm.key("Ксения Синицына"), ph.load_book(self.book))

    def test_previous_photo_of_unknown_source_is_dropped_when_wikidata_answers(self):
        rel = self.thumb()
        out = self.run_collect(["Ксения Синицына"], [], prev={"Ксения Синицына": rel})
        self.assertNotIn("Ксения Синицына", out)
        self.assertEqual(ph.load_book(self.book), {})
        self.assertTrue(any("личность не подтверждена" in x for x in ph._skip_rows(self.skip).values()))
        # и заново не принимается
        out = self.run_collect(["Ксения Синицына"], [], prev={"Ксения Синицына": rel})
        self.assertNotIn("Ксения Синицына", out)

    def test_missing_file_is_found_again(self):
        names = self.seed("Ксения Синицына", "photos/gone.jpg", 2)
        new = self.thumb("new.jpg")
        out = self.run_collect(["Ксения Синицына"], [("Kseniia SINITSYNA", "https://x/a", 2)], names=names,
                               make=lambda s, u: (new, "ok"))
        self.assertEqual(out["Ксения Синицына"], new)

    def test_prune_called_the_old_way_spares_remembered_files(self):
        rel = self.thumb()
        stray = self.thumb("stray.jpg")
        ph.save_book(self.book, {"k": {"f": rel}})
        self.assertEqual(ph.prune(self.site, set(), self.book), 1)
        self.assertTrue(os.path.exists(os.path.join(self.site, rel)))
        self.assertFalse(os.path.exists(os.path.join(self.site, stray)))

    def test_missing_file_without_source_is_not_shown(self):
        names = self.seed("Ксения Синицына", "photos/gone.jpg", 2)
        out = self.run_collect(["Ксения Синицына"], [], names=names)
        self.assertEqual(out, {})
        self.assertEqual(ph.load_book(self.book), {})

    def test_book_keeps_other_sections_of_people_json(self):
        with open(self.book, "w", encoding="utf-8") as f:
            json.dump({"pages": {"a": "b"}, "results": {}, "v": 4}, f)
        ph.save_book(self.book, {"k": {"f": "photos/a.jpg"}})
        with open(self.book, encoding="utf-8") as f:
            data = json.load(f)
        self.assertEqual(data["pages"], {"a": "b"})
        self.assertEqual(data["v"], 4)
        self.assertIn("k", data["photos"])


class SkipTest(Base):
    WIKI = "https://commons.wikimedia.org/wiki/Special:FilePath/A.jpg?width=500"

    def test_network_failure_does_not_blacklist_commons_url(self):
        with mock.patch.object(net, "fetch", side_effect=net.FetchError("429")), \
                mock.patch.object(ph, "_polite", lambda u: None):
            rel, status = ph.make2(self.site, self.WIKI)
        self.assertEqual((rel, status), (None, "fail"))
        out = self.run_collect(["Ксения Синицына"], [("Ksenia Sinitsyna", self.WIKI, 3)])
        self.assertNotIn("Ксения Синицына", out)
        self.assertEqual(ph.load_skip(self.skip), set())

    def test_group_photo_goes_to_skip(self):
        self.run_collect(["Ксения Синицына"], [("Ksenia Sinitsyna", self.WIKI, 3)],
                         make=lambda s, u: (None, "unsure"))
        self.assertEqual(ph.load_skip(self.skip), {self.WIKI})
        # и больше не пробуется
        calls = []
        self.run_collect(["Ксения Синицына"], [("Ksenia Sinitsyna", self.WIKI, 3)],
                         make=lambda s, u: calls.append(u) or (None, "unsure"))
        self.assertEqual(calls, [])

    def test_old_unversioned_skip_entries_are_reconsidered(self):
        with open(self.skip, "w", encoding="utf-8") as f:
            json.dump([self.WIKI], f)
        self.assertEqual(ph.load_skip(self.skip), set())

    def test_commons_is_fetched_at_larger_size(self):
        self.assertIn("width=960", ph.source_url(self.WIKI))
        self.assertEqual(ph.source_url("https://fsrussia.ru/a.jpg"), "https://fsrussia.ru/a.jpg")
        # имя файла миниатюры от прежнего адреса: готовые не пересобираются
        self.assertTrue(ph.rel_path(self.WIKI).endswith(".jpg"))


class SickHostTest(Base):
    def test_site_that_keeps_refusing_is_left_alone_and_nothing_is_lost(self):
        names = _names(*[f"Имя Фамилия{c}" for c in "абвгдежзий"])
        want = [f"Имя Фамилия{c}" for c in "абвгдежзий"]
        raw = [(f"Imia Familiia{c}", f"https://commons.wikimedia.org/wiki/Special:FilePath/{i}.jpg?width=500", 3)
               for i, c in enumerate("абвгдежзий")]
        calls = []
        out = self.run_collect(want, raw, names=names, is_image=lambda u: calls.append(u))
        self.assertEqual(out, {})
        self.assertEqual(len(calls), ph.SICK_AFTER)
        self.assertEqual(ph.load_skip(self.skip), set())


class NameVariantsTest(Base):
    def test_spelling_variants_find_the_photo(self):
        cases = [
            ("Любовь Рубцова", "Liubov RUBCOVA"),
            ("Анастасия Скопцова", "Anastasia Skoptcova"),
            ("Ольга Якушина", "Olga Jakušina"),
            ("Дарья Беклемищева", "Daria Beklemishcheva"),
            ("Софья Тютюнина", "Sofya TYUTYUNINA"),
        ]
        for ru, lat in cases:
            out = self.run_collect([ru], [(lat, "https://x/" + lat, 2)], names=_names(ru),
                                   make=lambda s, u: ("photos/n.jpg", "ok"))
            self.assertIn(ru, out, (ru, lat))
            os.unlink(self.book)

    def test_different_people_are_not_confused(self):
        for ru, lat in [("Ольга Фролова", "Olga ORLOVA"), ("Иван Иванов", "Ivan IVANOVA"),
                        ("Татьяна Козлова", "Tatiana KOZMAVA")]:
            out = self.run_collect([ru], [(lat, "https://x/a", 2)], names=_names(ru),
                                   make=lambda s, u: ("photos/n.jpg", "ok"))
            self.assertNotIn(ru, out, (ru, lat))

    def test_two_spellings_of_one_person_still_match(self):
        raw = [("Alexander VAKHNOV", "https://x/1", 2), ("Alexandr VAKHNOF", "https://x/2", 2)]
        out = self.run_collect(["Александр Вахнов"], raw, names=_names("Александр Вахнов"),
                               make=lambda s, u: ("photos/n.jpg", "ok"))
        self.assertIn("Александр Вахнов", out)

    def test_exact_label_of_another_listed_person_is_not_stolen(self):
        names = _names("Ольга Фёдорова", "Ольга Федорова")
        out = self.run_collect(["Ольга Фёдорова"], [("Olga FEDOROVA", "https://x/1", 2)], names=names,
                               make=lambda s, u: ("photos/n.jpg", "ok"))
        self.assertIn("Ольга Фёдорова", out)


class NamesTest(unittest.TestCase):
    def test_diacritics_fold(self):
        self.assertEqual(nm.norm_lat("Jakušina"), nm.norm_lat("Jakusina"))
        self.assertEqual(nm.key("Olga Jakušina"), nm.key("Olga JAKUSINA"))

    def test_ts_c(self):
        self.assertEqual(nm.key("Liubov Rubtsova"), nm.key("Liubov Rubcova"))
        self.assertEqual(nm.key("Любовь Рубцова"), nm.key("Liubov Rubcova"))


if __name__ == "__main__":
    unittest.main()


FIX = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")


def _cv():
    try:
        import cv2  # noqa: F401
        from PIL import Image  # noqa: F401
    except ImportError:
        raise unittest.SkipTest("нет OpenCV или Pillow")


class PortraitTest(unittest.TestCase):
    """Портретный контроль: Синицына в белой меховой шапке (Викисклад) — отказ."""

    def setUp(self):
        _cv()
        from PIL import Image
        self.Image = Image

    def im(self, name):
        return self.Image.open(os.path.join(FIX, name)).convert("RGB")

    def test_good_portrait_passes(self):
        self.assertIsNone(ph.portrait_problem(self.im("portrait_ok.jpg")))

    def test_ushanka_is_rejected(self):
        self.assertEqual(ph.portrait_problem(self.im("portrait_ushanka.jpg")), "головной убор")

    def test_blur_is_rejected(self):
        from PIL import ImageFilter
        blurred = self.im("portrait_ok.jpg").filter(ImageFilter.GaussianBlur(4))
        self.assertIn(ph.portrait_problem(blurred), ("размыто", "лица нет"))
        mild = self.im("portrait_ok.jpg").filter(ImageFilter.GaussianBlur(1.6))
        self.assertEqual(ph.portrait_problem(mild), "размыто")

    def test_two_faces_are_rejected(self):
        one = self.im("portrait_ok.jpg")
        two = self.Image.new("RGB", (ph.SIZE, ph.SIZE), "white")
        half = one.resize((128, 128))
        two.paste(half, (0, 40))
        two.paste(half, (128, 40))
        self.assertIn(ph.portrait_problem(two), ("лиц несколько", "лицо мелкое в кадре"))

    def test_no_face_is_rejected(self):
        self.assertEqual(ph.portrait_problem(self.Image.new("RGB", (256, 256), "gray")), "лица нет")

    def test_face_in_lower_part_is_rejected(self):
        one = self.im("portrait_ok.jpg")
        low = self.Image.new("RGB", (ph.SIZE, ph.SIZE), "white")
        low.paste(one, (0, 110))
        self.assertIsNotNone(ph.portrait_problem(low))

    def test_strict_wiki_cut_goes_to_skip_with_reason(self):
        _cv()
        import io
        buf = io.BytesIO()
        self.im("portrait_ushanka.jpg").resize((600, 600)).save(buf, "JPEG")
        with self.assertRaises(ph.Unsure) as cm:
            with tempfile.TemporaryDirectory() as t:
                ph._pil(buf.getvalue(), os.path.join(t, "a.jpg"), strict=True)
        self.assertEqual(str(cm.exception), "головной убор")


class ThumbAuditTest(Base):
    def test_wiki_entry_with_hat_is_dropped_with_reason(self):
        _cv()
        import shutil
        url = "https://commons.wikimedia.org/wiki/Special:FilePath/Hat.jpg?width=500"
        rel = "photos/hat.jpg"
        shutil.copy(os.path.join(FIX, "portrait_ushanka.jpg"), os.path.join(self.site, rel))
        names = self.seed("Ксения Синицына", rel, 3, url=url)
        out = self.run_collect(["Ксения Синицына"], [("Ksenia Sinitsyna", url, 3)], names=names)
        self.assertNotIn("Ксения Синицына", out)
        self.assertEqual(ph.load_book(self.book), {})
        self.assertEqual(ph._skip_rows(self.skip)[url], "головной убор")

    def test_wiki_entry_good_portrait_is_kept_and_marked(self):
        _cv()
        import shutil
        url = "https://commons.wikimedia.org/wiki/Special:FilePath/Ok.jpg?width=500"
        rel = "photos/ok.jpg"
        shutil.copy(os.path.join(FIX, "portrait_ok.jpg"), os.path.join(self.site, rel))
        names = self.seed("Ксения Синицына", rel, 3, url=url)
        out = self.run_collect(["Ксения Синицына"], [("Ksenia Sinitsyna", url, 3)], names=names)
        self.assertEqual(out["Ксения Синицына"], rel)
        self.assertEqual(ph.load_book(self.book)[nm.key("Ксения Синицына")]["q"], ph.QUALITY_V)

    def test_wiki_entry_not_among_verified_urls_is_dropped(self):
        rel = self.thumb()
        url = "https://commons.wikimedia.org/wiki/Special:FilePath/Other.jpg?width=500"
        names = self.seed("Ксения Синицына", rel, 3, url=url)
        out = self.run_collect(["Ксения Синицына"], [], names=names)
        self.assertNotIn("Ксения Синицына", out)

    def test_isu_entry_is_not_audited(self):
        rel = self.thumb()
        names = self.seed("Ксения Синицына", rel, 2)
        out = self.run_collect(["Ксения Синицына"], [], names=names)
        self.assertEqual(out["Ксения Синицына"], rel)
