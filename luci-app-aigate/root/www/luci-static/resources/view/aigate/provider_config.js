'use strict';
'require view';
'require uci';
'require ui';
'require fs';

var CSS = [
	':root, [data-theme="dark"] {',
	'  --p:#00d4aa; --p2:#00b894; --bg:#1a1d23; --card:#23272f;',
	'  --border:#333; --text:#e4e7ec; --muted:#889; --input-bg:#1a1d23;',
	'  --danger:#ff5050; --switch-bg:#555; --switch-knob:#fff;',
	'  --msg-ok-bg:rgba(0,212,170,.15); --msg-ok-border:#00d4aa;',
	'  --msg-err-bg:rgba(255,80,80,.15); --msg-err-border:#ff5050;',
	'}',
	'[data-theme="light"] {',
	'  --p:#00897b; --p2:#00695c; --bg:#f0f2f5; --card:#ffffff;',
	'  --border:#ddd; --text:#1a1a2e; --muted:#666; --input-bg:#f8f9fa;',
	'  --danger:#d32f2f; --switch-bg:#ccc; --switch-knob:#fff;',
	'  --msg-ok-bg:rgba(0,137,123,.1); --msg-ok-border:#00897b;',
	'  --msg-err-bg:rgba(211,47,47,.1); --msg-err-border:#d32f2f;',
	'}',
	'body{background:var(--bg);color:var(--text)}',
	'.peditx-app{padding:20px;max-width:860px;margin:0 auto}',
	'.card{background:var(--card);border:1px solid var(--border);border-radius:12px;padding:20px;margin-bottom:16px}',
	'.card h3{color:var(--p);margin:0 0 16px;font-size:1.1rem}',
	'.theme-switch{display:flex;align-items:center;gap:8px;position:fixed;top:12px;right:16px;z-index:100;background:var(--card);border:1px solid var(--border);border-radius:20px;padding:4px 12px;font-size:.85rem}',
	'.theme-switch input{width:36px;height:20px;appearance:none;-webkit-appearance:none;background:var(--switch-bg);border-radius:10px;position:relative;cursor:pointer;transition:background .3s;border:none;outline:none}',
	'.theme-switch input::after{content:"";position:absolute;top:2px;left:2px;width:16px;height:16px;border-radius:50%;background:var(--switch-knob);transition:transform .3s}',
	'.theme-switch input:checked{background:var(--p)}',
	'.theme-switch input:checked::after{transform:translateX(16px)}',
	'.btn{background:var(--p);color:#fff;border:none;padding:10px 20px;border-radius:8px;font-weight:600;cursor:pointer;transition:opacity .2s;margin-right:8px}',
	'.btn:hover{opacity:.85}.btn:disabled{opacity:.4;cursor:not-allowed}',
	'.btn-secondary{background:var(--switch-bg);color:var(--text)}',
	'.btn-danger{background:var(--danger);color:#fff}',
	'.msg{padding:12px;border-radius:8px;margin:12px 0;font-family:monospace;font-size:.9rem;display:none}',
	'.msg.ok{display:block;background:var(--msg-ok-bg);border:1px solid var(--msg-ok-border)}',
	'.msg.err{display:block;background:var(--msg-err-bg);border:1px solid var(--msg-err-border)}',
	'.log-box{background:#0d1117;color:#c9d1d9;border:1px solid var(--border);border-radius:8px;padding:16px;max-height:300px;overflow:auto;font-family:monospace;font-size:.85rem;white-space:pre-wrap}',
	'.badge{display:inline-block;padding:2px 8px;border-radius:10px;font-size:.75rem;font-weight:600;margin-left:8px}',
	'.badge.ok{background:rgba(0,212,170,.2);color:var(--p)}',
	'.badge.err{background:rgba(255,80,80,.2);color:var(--danger)}',
	'.toggle{display:flex;align-items:center;gap:10px;cursor:pointer;margin:8px 0}',
	'label.f{display:block;margin:10px 0 4px;font-weight:600}',
	'input.t,select.t{width:100%;padding:8px;border:1px solid var(--border);background:var(--input-bg);color:var(--text);border-radius:6px;box-sizing:border-box}'
].join('\n');

function applyTheme(light) {
	var el = document.documentElement;
	if (light) el.setAttribute('data-theme', 'light');
	else el.removeAttribute('data-theme');
	localStorage.setItem('aigate_theme', light ? 'light' : 'dark');
}

function themeSwitch() {
	var saved = localStorage.getItem('aigate_theme');
	return E('div', { 'class': 'theme-switch' }, [
		E('span', {}, '☀️'),
		E('input', { 'type': 'checkbox', 'id': 'theme-toggle',
			'checked': (saved === 'light') ? 'checked' : null,
			'change': function() { applyTheme(this.checked); } }),
		E('span', {}, '🌙')
	]);
}


// PRESETS loaded from /usr/share/aigate/providers.json at runtime
var PRESETS = null;

return view.extend({
	load: function() {
		var m = window.location.search.match(/section=([A-Za-z0-9_]+)/);
		return Promise.all([
			uci.load('aigate'),
			fs.read_direct('/usr/share/aigate/providers.json', 'text')
				.then(function(raw) { return JSON.parse(raw).providers || {}; })
				.catch(function() { return {}; })
		]).then(function(r) { return { sec: m ? m[1] : null, presets: r[1] }; });
	},

	render: function(name) {
		var self = this;
		var sec = name ? uci.get('aigate', name) : {};
		sec = sec || {};

		var nameEl = E('input', { 'class': 't', 'type': 'text', 'value': name || '' });
		if (!PRESETS['custom']) PRESETS['custom'] = null;
		var presetEl = E('select', { 'class': 't', 'change': function() {
				var p = PRESETS[this.value];
				if (p) { typeEl.value = p.type; urlEl.value = p.url; }
			} }, Object.keys(PRESETS).map(function(k) {
				return E('option', { 'value': k }, k);
			}));
		var embEl = E('input', { 'type': 'checkbox',
			'checked': sec.embeddings === '1' ? 'checked' : null });
		var imgEl = E('input', { 'type': 'checkbox',
			'checked': sec.images === '1' ? 'checked' : null });
		var typeEl = E('select', { 'class': 't' }, [
			E('option', { 'value': 'anthropic', 'selected': sec.type === 'anthropic' ? 'selected' : null },
				'anthropic — Claude-style API (/messages)'),
			E('option', { 'value': 'openai', 'selected': sec.type === 'openai' ? 'selected' : null },
				'openai — OpenAI-style API (/chat/completions)')
		]);
		var urlEl = E('input', { 'class': 't', 'type': 'text', 'value': sec.base_url || '',
			'placeholder': 'https://api.anthropic.com/v1' });
		var modelsEl = E('input', { 'class': 't', 'type': 'text', 'value': sec.models || '',
			'placeholder': 'claude-sonnet-4-5, gpt-4o' });
		var headersEl = E('input', { 'class': 't', 'type': 'text', 'value': sec.headers || '',
			'placeholder': 'X-Attestation: abc|User-Agent: opencode/1' });

		return E([ E('style', { 'type': 'text/css' }, CSS), themeSwitch(),
			E('div', { 'class': 'peditx-app' }, [
			E('div', { 'class': 'card' }, [
				E('h3', {}, name ? ('Config: ' + name) : 'Add provider'),
				E('div', { 'class': 'hint' },
					'One upstream endpoint. Accounts (keys) are attached on the Accounts tab.'),
				E('label', { 'class': 'f' }, 'Preset (fills dialect + URL)'),
				presetEl,
				E('div', { 'class': 'hint' },
					'Pick a known upstream (like the 9Router registry), then adjust below. ' +
					'opencode-zen/go need their attestation headers in Extra headers.'),
				E('label', { 'class': 'f' }, 'Name'),
				nameEl,
				E('label', { 'class': 'f' }, 'Dialect'),
				typeEl,
				E('label', { 'class': 'f' }, 'Base URL'),
				urlEl,
				E('div', { 'class': 'hint' },
					'Include the path prefix the provider expects, e.g. /v1 or /v1beta/openai or /inference/v1.'),
				E('label', { 'class': 'f' }, 'Models catalog'),
				modelsEl,
				E('div', { 'class': 'hint' },
					'Comma-separated model names this provider serves. Empty = accepts any model.'),
				E('label', { 'class': 'f' }, 'Extra headers'),
				headersEl,
				E('div', { 'class': 'hint' }, 'Pipe-separated. For providers needing attestation/fingerprint headers.'),
				E('label', { 'class': 'f' }, 'Capabilities of this provider'),
				E('label', {}, [ embEl, ' embeddings (/v1/embeddings)' ]),
				E('label', {}, [ imgEl, ' image generation (/v1/images/generations)' ]),
				E('div', { 'style': 'margin-top:16px' }, [
					E('button', { 'class': 'btn', 'click': ui.createHandlerFn(self, 'handleSave',
						name, nameEl, typeEl, urlEl, modelsEl, headersEl, embEl, imgEl) }, 'Save'),
					E('button', { 'class': 'btn btn-secondary', 'click': function() {
						window.location.href = L.url('admin/ai/aigate/providers');
					} }, 'Back')
				])
			])
		]) ]);
	},

	handleSave: function(oldName, nameEl, typeEl, urlEl, modelsEl, headersEl, embEl, imgEl) {
		var name = nameEl.value.trim().replace(/[^A-Za-z0-9_]/g, '');
		if (!name) { ui.addNotification(E('p', {}, 'Name is required.')); return; }
		var chain = Promise.resolve();
		if (oldName && oldName !== name) {
			chain = chain.then(function() { uci.del('aigate', oldName); });
		}
		return chain.then(function() {
			uci.add('aigate', 'provider', name);
			uci.set('aigate', name, 'type', typeEl.value);
			uci.set('aigate', name, 'base_url', urlEl.value.trim());
			uci.set('aigate', name, 'models', modelsEl.value.trim());
			uci.set('aigate', name, 'headers', headersEl.value.trim());
			uci.set('aigate', name, 'embeddings', embEl.checked ? '1' : '0');
			uci.set('aigate', name, 'images', imgEl.checked ? '1' : '0');
			return uci.save().then(function() { return uci.commit('aigate'); });
		}).then(function() {
			window.location.href = L.url('admin/ai/aigate/providers');
		}).catch(function(err) {
			ui.addNotification(E('p', {}, 'Save failed: ' + err));
		});
	}
});
