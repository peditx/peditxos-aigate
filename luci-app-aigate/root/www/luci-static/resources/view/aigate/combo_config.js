'use strict';
'require view';
'require uci';
'require ui';

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


return view.extend({
	load: function() {
		var m = window.location.search.match(/section=([A-Za-z0-9_]+)/);
		return uci.load('aigate').then(function() { return m ? m[1] : null; });
	},

	render: function(name) {
		var self = this;
		var sec = (name && uci.get('aigate', name)) || {};

		var nameEl = E('input', { 'class': 't', 'type': 'text', 'value': name || '',
			'placeholder': 'smart, cheap-fast, free-only ...' });
		var chainEl = E('textarea', { 'class': 't', 'rows': '5',
			'placeholder': 'claude-sonnet-4-5\ngpt-4o\nllama-3.3-70b' }, sec.chain || '');

		return E([ E('style', { 'type': 'text/css' }, CSS), themeSwitch(),
			E('div', { 'class': 'peditx-app' }, [
			E('div', { 'class': 'card' }, [
				E('h3', {}, name ? ('Combo: ' + name) : 'Add combo'),
				E('div', { 'class': 'hint' },
					'Clients send model="<combo name>" and the gateway walks this chain, ' +
					'using the same tier/round-robin fallback per step — like 9Router combos.'),
				E('label', { 'class': 'f' }, 'Combo name (used as the model id)'),
				nameEl,
				E('label', { 'class': 'f' }, 'Model chain (one per line, tried in order)'),
				chainEl,
				E('div', { 'style': 'margin-top:16px' }, [
					E('button', { 'class': 'btn', 'click': ui.createHandlerFn(self, 'handleSave',
						name, nameEl, chainEl) }, 'Save'),
					E('button', { 'class': 'btn btn-secondary', 'click': function() {
						window.location.href = L.url('admin/ai/aigate/combos');
					} }, 'Back')
				])
			])
		]) ]);
	},

	handleSave: function(oldName, nameEl, chainEl) {
		var name = nameEl.value.trim().replace(/[^A-Za-z0-9_.-]/g, '');
		if (!name) { ui.addNotification(E('p', {}, 'Name is required.')); return; }
		var chain = chainEl.value.split(/[\n,]/).map(function(s) {
			return s.trim();
		}).filter(Boolean).join(',');
		var run = Promise.resolve();
		if (oldName && oldName !== name) {
			run = run.then(function() { uci.del('aigate', oldName); });
		}
		return run.then(function() {
			uci.add('aigate', 'combo', name);
			uci.set('aigate', name, 'chain', chain);
			return uci.save().then(function() { return uci.commit('aigate'); });
		}).then(function() {
			window.location.href = L.url('admin/ai/aigate/combos');
		}).catch(function(err) {
			ui.addNotification(E('p', {}, 'Save failed: ' + err));
		});
	}
});
