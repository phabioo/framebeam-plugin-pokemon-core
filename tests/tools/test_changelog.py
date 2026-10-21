import os, sys, unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools"))
import changelog as cl


def body(section):
    return "## Summary\n\nx\n\n## Changelog\n\n%s\n\n## How tested\n\ny\n" % section


class CheckTest(unittest.TestCase):
    def status(self, text):
        return cl.parse_section(text)[0]

    def test_valid(self):
        s, e, err = cl.parse_section(body("<!-- hint -->\n### Added\n- One\n  continued\n### Fixed\n- Hub: Two"))
        self.assertEqual((s, err), ("entries", []))
        self.assertEqual(e, [("Added", "One continued"), ("Fixed", "Hub: Two")])

    def test_none(self):
        self.assertEqual(self.status(body("<!-- c -->\nNone")), "none")

    def test_missing(self):
        self.assertEqual(self.status("## Summary\nx"), "missing")

    def test_unknown_heading(self):
        s, _, err = cl.parse_section(body("### Misc\n- x"))
        self.assertEqual(s, "invalid")
        self.assertIn("Misc", err[0])

    def test_empty_bullet_and_no_bullet(self):
        self.assertEqual(self.status(body("### Added\n-")), "invalid")
        self.assertEqual(self.status(body("### Added\n")), "invalid")
        self.assertEqual(self.status(body("")), "invalid")
        self.assertEqual(self.status(body("- no heading")), "invalid")

    def test_none_with_more_is_invalid(self):
        self.assertEqual(self.status(body("none\n### Added\n- x")), "invalid")

    def test_bot_passes_and_cli(self):
        class A:
            body_file = None
            author = "dependabot[bot]"
        os.environ["PR_BODY"] = ""
        self.assertEqual(cl.cmd_check(A), 0)
        A.author = "someone"
        self.assertEqual(cl.cmd_check(A), 1)
        os.environ["PR_BODY"] = body("none")
        self.assertEqual(cl.cmd_check(A), 0)


PRS = {
    1: {"title": "Add thing", "html_url": "u/1", "user": {"login": "a"}, "body": body("### Added\n- Hub: Thing\n- Shared line\n### Fixed\n- Player: Crash")},
    2: {"title": "CI work", "html_url": "u/2", "user": {"login": "a"}, "body": body("none")},
    3: {"title": "Old style PR", "html_url": "u/3", "user": {"login": "a"}, "body": "no section"},
    4: {"title": "Bump foo", "html_url": "u/4", "user": {"login": "dependabot[bot]"}, "body": ""},
    5: {"title": "Again", "html_url": "u/5", "user": {"login": "a"}, "body": body("### Added\n- Shared line")},
}
LOG = [("s1", "Merge pull request #1 from x/y"), ("s2", "Merge pull request #2 from x/y"), ("s3", "Fix it (#3)"),
       ("s4", "Merge pull request #4 from x/y"), ("s5", "Merge pull request #5 from x/y"), ("s6", "direct commit")]


def fake_api(path):
    if path.endswith("/pulls"):
        raise RuntimeError("no PR")
    return PRS[int(path.rsplit("/", 1)[1])]


def run(product=None):
    return cl.collect("o/r", "a", "b", product, lambda b, h: LOG, fake_api)


class CollectTest(unittest.TestCase):
    def test_all(self):
        g = run()
        self.assertEqual(list(g), ["Added", "Changed", "Fixed", "Dependencies", "Other"])
        self.assertEqual(g["Added"][1], ("Shared line", [(1, "u/1"), (5, "u/5")]))   # deduplicated, both PRs
        self.assertEqual(g["Changed"], [("Old style PR", [(3, "u/3")])])             # fallback to the title
        self.assertEqual(g["Dependencies"], [("Bump foo", [(4, "u/4")])])
        self.assertEqual(g["Other"], [("direct commit", [])])

    def test_product_filter(self):
        hub = run("hub")
        self.assertEqual([t for t, _ in hub["Added"]], ["Thing", "Shared line"])
        self.assertNotIn("Fixed", hub)
        player = run("player")
        self.assertEqual([t for t, _ in player["Added"]], ["Shared line"])
        self.assertEqual(player["Fixed"][0][0], "Crash")

    def test_pr_lookup_by_sha(self):
        def api(path):
            if path.endswith("/pulls"):
                return [{"number": 1}]
            return PRS[1]
        g = cl.collect("o/r", "a", "b", None, lambda b, h: [("s", "plain subject")], api)
        self.assertIn("Added", g)

    def test_markdown(self):
        md = cl.render_markdown(run("hub"), "## T", "http://c", 3)
        self.assertIn("### Added\n\n- Thing ([#1](u/1))\n", md)
        self.assertIn("- Shared line ([#1](u/1), [#5](u/5))", md)
        self.assertTrue(md.startswith("## T\n\n"))
        self.assertTrue(md.rstrip().endswith("Full changelog: http://c"))
        self.assertIn("No user-visible changes.", cl.render_markdown({}))

    def test_index_plain_and_truncated(self):
        idx = cl.render_index(run("hub"))
        self.assertNotIn("](", idx)
        self.assertTrue(idx.startswith("Added:\n- Thing\n"))
        self.assertEqual(cl.render_index({}), "")
        big = {"Added": [("x" * 90 + str(i), []) for i in range(200)], "Fixed": [("fix", [])]}
        out = cl.render_index(big)
        self.assertLessEqual(len(out.encode()), cl.INDEX_MAX_BYTES)
        last = out.rstrip("\n").split("\n")[-1]
        self.assertRegex(last, r"^\.\.\. and \d+ more \(see the release notes\)$")
        kept = out.count("\n- ")
        self.assertEqual(int(last.split()[2]), 201 - kept)

    def test_index_utf8_limit(self):
        big = {"Added": [("ü" * 100, []) for _ in range(100)]}
        self.assertLessEqual(len(cl.render_index(big).encode("utf-8")), cl.INDEX_MAX_BYTES)

    def test_control_characters(self):
        self.assertEqual(cl.clean_line("a\r\x00b\x7f\x85  c\td"), "a b c d")
        pr = dict(PRS[1], body=body("### Added\n- Bad\x07 line\x9f  here"))
        g = cl.collect("o/r", "a", "b", None, lambda b, h: [("s", "Merge pull request #1 from x")], lambda p: pr)
        self.assertEqual(g["Added"][0][0], "Bad line here")
        idx = cl.render_index({"Added": [("x\ry\x01z", [])]})
        self.assertEqual(idx, "Added:\n- x y z\n")

    def test_pr_number(self):
        self.assertEqual(cl.pr_number("Merge pull request #12 from a/b"), 12)
        self.assertEqual(cl.pr_number("feat: x (#7)"), 7)
        self.assertIsNone(cl.pr_number("plain"))


if __name__ == "__main__":
    unittest.main()
