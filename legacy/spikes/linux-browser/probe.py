"""Generated-only WebKitGTK feasibility probe. Never opens VK or an existing profile."""
import argparse
from http.server import ThreadingHTTPServer
import json
from pathlib import Path
import threading
import tempfile

import gi
gi.require_version('Gtk', '3.0')
gi.require_version('Gdk', '3.0')
gi.require_version('WebKit2', '4.1')
from gi.repository import Gdk, GLib, Gtk, WebKit2

from fixture import Fixture

class Probe:
    def __init__(self, output, visible_control=False):
        self.output, self.checks, self.views, self.windows = output, {}, [], []
        self.observations = 0
        self.done = False
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = f'http://127.0.0.1:{self.server.server_port}'
        ephemeral = WebKit2.WebContext.new_ephemeral()
        self.checks['ephemeral_session'] = ephemeral.get_website_data_manager().is_ephemeral()
        # Engine alone uses this new generated-only session; never inspect its files.
        self.state = Path(tempfile.mkdtemp(prefix='ownsemble-generated-browser-'))
        manager = WebKit2.WebsiteDataManager(base_data_directory=str(self.state / 'data'),
                                               base_cache_directory=str(self.state / 'cache'))
        manager.set_persistent_credential_storage_enabled(False)
        self.context = WebKit2.WebContext.new_with_website_data_manager(manager)
        self.checks['dedicated_session'] = not manager.is_ephemeral()
        self.context.set_sandbox_enabled(True)
        self.context.set_cache_model(WebKit2.CacheModel.WEB_BROWSER)
        self.checks['sandbox_enabled'] = self.context.get_sandbox_enabled()
        manager = self.context.get_website_data_manager()
        self.checks['tls_fail_closed'] = manager.get_tls_errors_policy() == WebKit2.TLSErrorsPolicy.FAIL
        for index in range(2):
            scripts = WebKit2.UserContentManager()
            scripts.add_script(WebKit2.UserScript.new('window.injected=true;',
                WebKit2.UserContentInjectedFrames.TOP_FRAME,
                WebKit2.UserScriptInjectionTime.START, None, None))
            view = WebKit2.WebView(web_context=self.context, user_content_manager=scripts)
            view.set_is_muted(True)
            self.checks['native_mute_before_load'] = self.checks.get('native_mute_before_load', True) and view.get_is_muted()
            view.connect('permission-request', lambda _, request: (request.deny(), True)[1])
            view.connect('decide-policy', self.policy)
            view.connect('resource-load-started', self.resource)
            view.connect('web-process-terminated', lambda *_: self.finish('web_process_terminated'))
            window = Gtk.Window(title='Ownsemble GENERATED browser control') if visible_control else Gtk.OffscreenWindow()
            window.set_default_size(640, 480)
            window.add(view)
            window.show_all()
            self.views.append(view)
            self.windows.append(window)
            view.load_uri(self.base + f'/page{index}')
        GLib.timeout_add(1500, self.click)
        GLib.timeout_add_seconds(6, self.collect)
        GLib.timeout_add_seconds(20, lambda: self.finish('probe_timeout'))

    def policy(self, _, decision, kind):
        if kind == WebKit2.PolicyDecisionType.NAVIGATION_ACTION:
            if not decision.get_navigation_action().get_request().get_uri().startswith(self.base + '/'):
                decision.ignore()
                return True
        return False

    def resource(self, _, resource, request):
        if request.get_uri() == self.base + '/asset':
            self.observations += 1

    def click(self):
        view = self.views[0]
        view.grab_focus()
        self.windows[0].set_focus(view)
        focus = Gdk.Event.new(Gdk.EventType.FOCUS_CHANGE)
        focus.window = self.windows[0].get_window()
        focus.in_ = True
        self.windows[0].event(focus)
        pointer = Gdk.Display.get_default().get_default_seat().get_pointer()
        for kind in (Gdk.EventType.MOTION_NOTIFY, Gdk.EventType.BUTTON_PRESS, Gdk.EventType.BUTTON_RELEASE):
            event = Gdk.Event.new(kind)
            event.window = view.get_window()
            event.send_event = True
            event.time = Gdk.CURRENT_TIME
            event.x, event.y = 60.0, 60.0
            event.set_device(pointer)
            if kind != Gdk.EventType.MOTION_NOTIFY:
                event.button = 1
            view.event(event)
        return False

    def evaluate(self, view, expression, callback):
        def completed(obj, result, *_):
            try:
                value = obj.evaluate_javascript_finish(result)
                callback(json.loads(value.to_string()))
            except Exception:
                self.finish('evaluation_failed')
        view.evaluate_javascript(expression, -1, None, None, None, completed, None)

    def collect(self):
        self.evaluate(self.views[0], "JSON.stringify({...fixture,audioReady:document.querySelector('audio').readyState,audioNetwork:document.querySelector('audio').networkState,audioCode:document.querySelector('audio').error?.code||0,audioTime:document.querySelector('audio').currentTime,audioPaused:document.querySelector('audio').paused,domUnmuted:!document.querySelector('audio').muted&&document.querySelector('audio').volume===1,wavSupport:document.querySelector('audio').canPlayType('audio/wav'),mp3Support:document.querySelector('audio').canPlayType('audio/mpeg'),visibility:document.visibilityState})", self.first)
        return False

    def first(self, data):
        self.audio_error = data.get('audioError')
        self.audio_state = {key: data[key] for key in ('audioReady', 'audioNetwork', 'audioCode', 'audioTime', 'audioPaused', 'domUnmuted', 'wavSupport', 'mp3Support', 'visibility')}
        self.checks.update(document_start=data['start'], trusted_click=data['click'], focused_click=data['focus'],
                           audio_playing_while_native_muted=data['playing'] and data['audioCode'] == 0 and data['domUnmuted'] and self.views[0].get_is_muted(),
                           media_clock_advanced=data['audioTime'] > 0 and not data['audioPaused'] and data['audioCode'] == 0,
                           cached_request_observed=self.observations >= 2 and Fixture.asset_requests == 1,
                           hidden_document=all(isinstance(w, Gtk.OffscreenWindow) for w in self.windows))
        self.evaluate(self.views[1], 'JSON.stringify(fixture.click===false && fixture.start===true)', self.second)

    def second(self, independent):
        self.checks['independent_document'] = independent
        self.finish(None)

    def finish(self, category):
        if self.done:
            return False
        self.done = True
        for view in self.views:
            view.stop_loading()
        for window in self.windows:
            window.destroy()
        self.server.shutdown()
        self.server.server_close()
        self.checks['closed_cleanly'] = category is None
        result = {'engine': 'WebKitGTK', 'version': '.'.join(str(f()) for f in
                  (WebKit2.get_major_version, WebKit2.get_minor_version, WebKit2.get_micro_version)),
                  'fixture_only': True, 'checks': self.checks,
                  'audio_error_category': getattr(self, 'audio_error', None),
                  'fixture_audio_state': getattr(self, 'audio_state', {}),
                  'media_enabled': self.views[0].get_settings().get_enable_media(),
                  'fixture_network_audio_requests': Fixture.audio_requests,
                  'fixture_network_asset_requests': Fixture.asset_requests,
                  'fixture_asset_observations': self.observations, 'error_category': category}
        self.output.parent.mkdir(parents=True, exist_ok=True)
        self.output.write_text(json.dumps(result, indent=2) + '\n')
        GLib.idle_add(Gtk.main_quit)
        return False

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--visible-control', action='store_true')
    args = parser.parse_args()
    probe = Probe(args.output, args.visible_control)
    Gtk.main()
