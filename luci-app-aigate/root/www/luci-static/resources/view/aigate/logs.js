'use strict';
'require view';
'require fs';
'require ui';

var LOG_PATH = '/tmp/aigate-update.log';
var REQ_LOG = '/root/.aigate/requests.log';

var CSS = [
	':root, [data-theme="dark"] {',
	'  --p:#00d4aa; --bg:#1a1d23; --card:#23272f; --border:#333; --text:#e4e7ec;',
	'  --muted:#889; --switch-bg:#555; --switch-knob:#fff; --log-bg:#0d1117; --log-text:#c9d1d9;',
	'}',
	'[data-theme="light"] {',
	'  --p:#00897b; --bg:#f0f2f5; --card:#ffffff; --border:#ddd; --text:#1a1a2e;',
	'  --muted:#666; --switch-bg:#ccc; --switch-knob:#fff; --log-bg:#f5f5f5; --log-text:#333;',
	'}',
	'body{background:var(--bg);color:var(--text)}',
	'.peditx-app{padding:20px;max-width:960px;margin:0 auto}',
	'.card{background:var(--card);border:1px solid var(--border);border-radius:12px;padding:20px;margin-bottom:16px}',
	'.card h3{color:var(--p);margin:0 0 16px;font-size:1.1rem}',
	'.theme-switch{display:flex;align-items:center;gap:8px;position:fixed;top:12px;right:16px;z-index:100;background:var(--card);border:1px solid var(--border);border-radius:20px;padding:4px 12px;font-size:.85rem}',
	'.theme-switch input{width:36px;height:20px;appearance:none;-webkit-appearance:none;background:var(--switch-bg);border-radius:10px;position:relative;cursor:pointer;transition:background .3s;border:none;outline:none}',
	'.theme-switch input::after{content:"";position:absolute;top:2px;left:2px;width:16px;height:16px;border-radius:50%;background:var(--switch-knob);transition:transform .3s}',
	'.theme-switch input:checked{background:var(--p)}',
	'.theme-switch input:checked::after{transform:translateX(16px)}',
	'.btn{background:var(--p);color:#fff;border:none;padding:8px 16px;border-radius:8px;font-weight:600;cursor:pointer;margin-right:6px}',
	'.btn-secondary{background:var(--switch-bg);color:var(--text)}',
	'.log-box{background:var(--log-bg);color:var(--log-text);border:1px solid var(--border);border-radius:8px;padding:16px;max-height:500px;overflow:auto;font-family:monospace;font-size:.85rem;white-space:pre-wrap}',
	'.hint{color:var(--muted);font-size:.8rem}'
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
		E('input', { 'type': 'checkbox', 'checked': (saved === 'light') ? 'checked' : null,
			'change': function() { applyTheme(this.checked); } }),
		E('span', {}, '🌙')
	]);
}

return view.extend({
	load: function() {
		return Promise.all([
			fs.read_direct(REQ_LOG, 'text').catch(function() { return ''; }),
			fs.read_direct(LOG_PATH, 'text').catch(function() { return ''; })
		]);
	},

	render: function(data) {
		var self = this;
		this.reqEl = E('pre', { 'class': 'log-box' }, self.fmtReqs(String(data[0] || '')));
		this.updEl = E('pre', { 'class': 'log-box' }, String(data[1] || '(no update log yet)'));

		return E([ E('style', { 'type': 'text/css' }, CSS), themeSwitch(),
			E('div', { 'class': 'peditx-app' }, [
				E('div', { 'class': 'card' }, [
					E('h3', {}, 'Request Log (live quota: quota is enforced per account/day)'),
					E('div', { 'style': 'margin-bottom:10px' }, [
						E('button', { 'class': 'btn',
							'click': ui.createHandlerFn(self, 'handleRefresh') }, 'Refresh')
					]),
					this.reqEl
				]),
				E('div', { 'class': 'card' }, [
					E('h3', {}, 'Update Log'),
					this.updEl
				])
			]) ]);
	},

	fmtReqs: function(text) {
		var lines = text.trim().split('\n').filter(Boolean);
		if (!lines.length) return '(no requests yet — they appear here as clients use the gateway)';
		return lines.slice(-200).reverse().map(function(l) {
			var o = null;
			try { o = JSON.parse(l); } catch (e) { return l; }
			if (!o) return l;
			var u = o.usage ? ((o.usage.prompt_tokens || o.usage.input_tokens || 0)
				+ '/' + (o.usage.completion_tokens || o.usage.output_tokens || 0)) : '-';
			return (o.time || '') + '  ' + (o.status || '')
				+ '  ' + (o.provider || '?') + '/' + (o.account || '?')
				+ '  model=' + (o.model || '?')
				+ (o.translated ? ' [translated]' : '')
				+ (o.stream ? ' [stream]' : '')
				+ '  tok=' + u
				+ '  ' + (o.elapsed || 0) + 's';
		}).join('\n');
	},

	handleRefresh: function() {
		var self = this;
		return fs.read_direct(REQ_LOG, 'text').catch(function() { return ''; })
			.then(function(text) {
				self.reqEl.textContent = self.fmtReqs(String(text));
			});
	}
});
