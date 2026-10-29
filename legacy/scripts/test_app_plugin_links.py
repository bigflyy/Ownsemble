"""Generated link planning only; no plugin cache or OS privileges required."""
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import json

SCRIPT = Path(__file__).with_name('app-plugin-links.py').resolve()


class PluginLinksTests(unittest.TestCase):
    def test_all_present_desktop_projects_get_only_workspace_junctions(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            project = root / 'app'
            for platform in ('windows', 'linux'):
                (project / platform).mkdir(parents=True)
            target = root / 'generated-package'
            target.mkdir()
            plugins = {p: [{'name': 'generated_plugin', 'path': str(target)}]
                       for p in ('windows', 'linux')}
            (project / '.flutter-plugins-dependencies').write_text(json.dumps({'plugins': plugins}))
            # Run the actual entry point with only its repository location and
            # OS command mocked. Generated paths are all inside this fixture.
            with patch('pathlib.Path.resolve', autospec=True, side_effect=lambda p: p.absolute()), \
                 patch('subprocess.run') as command:
                source = SCRIPT.read_text()
                exec(compile(source, str(SCRIPT), 'exec'),
                     {'__file__': str(root / 'scripts/app-plugin-links.py'), '__name__': '__main__'})
            destinations = [Path(call.args[0][-2]) for call in command.call_args_list]
            self.assertEqual(set(destinations), {
                project / p / 'flutter/ephemeral/.plugin_symlinks/generated_plugin'
                for p in ('windows', 'linux')})
            for call in command.call_args_list:
                self.assertEqual(call.args[0][:5], ['cmd.exe', '/d', '/c', 'mklink', '/J'])


if __name__ == '__main__':
    unittest.main()
