"""Local tests of the exact-overlay guard, using tiny disposable git repos."""
import pathlib
import subprocess
import tempfile
import unittest


RECIPE = pathlib.Path(__file__).resolve().parents[1]


class OverlayTest(unittest.TestCase):
    def test_exact_overlay_and_unrelated_work(self):
        with tempfile.TemporaryDirectory(prefix='oxcoder-overlay-test-') as tmp:
            root = pathlib.Path(tmp)
            recipe, runtime = root / 'recipe', root / 'runtime'
            (recipe / 'patches').mkdir(parents=True)
            runtime.mkdir()
            (recipe / 'prepare-runtime.sh').write_bytes((RECIPE / 'prepare-runtime.sh').read_bytes())

            def git(*args):
                return subprocess.check_output(['git', '-C', str(runtime), *args], text=True)

            git('init', '-q')
            git('config', 'user.name', 'Overlay test')
            git('config', 'user.email', 'test@localhost')
            source = runtime / 'source.txt'
            source.write_text('base\n')
            git('add', 'source.txt')
            git('commit', '-qm', 'base')
            revision = git('rev-parse', 'HEAD').strip()
            source.write_text('fairness\n')
            (recipe / 'patches/prefill-fairness.patch').write_text(git('diff', '--binary', '--full-index'))
            source.write_text('base\n')

            def prepare():
                return subprocess.run(['bash', str(recipe / 'prepare-runtime.sh'), str(runtime), revision],
                                      capture_output=True, text=True)

            self.assertEqual(prepare().returncode, 0)
            self.assertEqual(source.read_text(), 'fairness\n')
            self.assertEqual(prepare().returncode, 0, 'idempotent restart')
            source.write_text('unrelated edit\n')
            self.assertNotEqual(prepare().returncode, 0)
            self.assertEqual(source.read_text(), 'unrelated edit\n')
            source.write_text('fairness\n')
            extra = runtime / 'untracked.txt'
            extra.write_text('preserve me\n')
            self.assertNotEqual(prepare().returncode, 0)
            self.assertEqual(extra.read_text(), 'preserve me\n')
            git('add', 'untracked.txt')
            self.assertNotEqual(prepare().returncode, 0)


if __name__ == '__main__':
    unittest.main()
